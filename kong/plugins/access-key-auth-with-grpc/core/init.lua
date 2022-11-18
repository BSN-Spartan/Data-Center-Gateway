local redis = require "resty.redis"
local kong = kong
local reports = require "kong.reports"
local null = ngx.null
local cjson = require "cjson"
local sock_opts = {}
local fmt = string.format
local timestamp = require "kong.tools.timestamp"
local EXPIRATION = require "kong.plugins.access-key-auth-with-grpc.expiration"

local function get_full_key_name(conf, accessKey)
    return string.lower(conf.keySymbol .. "-" .. accessKey)
end

local function is_present(str)
    return str and str ~= "" and str ~= null
end

local get_local_key = function(accessKey, period, period_date)
    --local service_id, route_id = get_service_and_route_ids(conf)
    return fmt("ratelimit:%s:%s:%s", accessKey, period_date, period)
end


local function get_redis_connection(conf)
  local red = redis:new()
  --red:set_timeout(conf.redis_timeout)
  red:set_timeouts(conf.redis_timeout,conf.redis_timeout,conf.redis_timeout)

  sock_opts.ssl = conf.redis_ssl
  sock_opts.ssl_verify = conf.redis_ssl_verify
  sock_opts.server_name = conf.redis_server_name

  -- use a special pool name only if redis_database is set to non-zero
  -- otherwise use the default pool name host:port
  sock_opts.pool = conf.redis_database and
                    conf.redis_host .. ":" .. conf.redis_port ..
                    ":" .. conf.redis_database
  local ok, err = red:connect(conf.redis_host, conf.redis_port,
                              sock_opts)
  if not ok then
    kong.log.err("failed to connect to Redis: ", err)
    return nil, err
  end

  local times, err = red:get_reused_times()
  if err then
    kong.log.err("failed to get connect reused times: ", err)
    return nil, err
  end

  if times == 0 then
    if is_present(conf.redis_password) then
      local ok, err = red:auth(conf.redis_password)
      if not ok then
        kong.log.err("failed to auth Redis: ", err)
        return nil, err
      end
    end

    if conf.redis_database ~= 0 then
      -- Only call select first time, since we know the connection is shared
      -- between instances that use the same redis database

      local ok, err = red:select(conf.redis_database)
      if not ok then
        kong.log.err("failed to change Redis database: ", err)
        return nil, err
      end
    end
  end

  return red
end


return {
    increment = function(conf, limits, identifier, current_timestamp, value)
      local red, err = get_redis_connection(conf)
      if not red then
        kong.log.err("get_redis_connection err:",err)
        return nil, err
      end

      local periods = timestamp.get_timestamps(current_timestamp)
      red:init_pipeline()
      for period, period_date in pairs(periods) do
        if limits[period] then
          local cache_key = get_local_key(identifier, period, period_date)
          --kong.log.debug("increment cache_key:", cache_key)
          red:eval([[
            local key, value, expiration = KEYS[1], tonumber(ARGV[1]), ARGV[2]

            if redis.call("incrby", key, value) == value then
              redis.call("expire", key, expiration)
            end
          ]], 1, cache_key, value, EXPIRATION[period])
        end
      end
      local _, err = red:commit_pipeline()
      if err then
        kong.log.err("failed to commit increment pipeline in Redis: ", err)
        return nil, err
      end

      local ok, err = red:set_keepalive(10000, 10000)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
        return nil, err
      end

      return true
    end,

    usage = function(conf, accessKey, period, current_timestamp)
      local red, err = get_redis_connection(conf)
      if not red then
        kong.log.err("get_redis_connection err:",err)
        return nil, err
      end

      reports.retrieve_redis_version(red)

      local periods = timestamp.get_timestamps(current_timestamp)
      local cache_key = get_local_key(accessKey, period, periods[period])
      --kong.log.debug("usage cache_key:", cache_key)

      local current_metric, err = red:get(cache_key)
      if err then
        return nil, err
      end

      if current_metric == null then
        current_metric = nil
      end

      local ok, err = red:set_keepalive(10000, 10000)
      if not ok then
        kong.log.err("failed to set Redis keepalive: ", err)
      end

      return current_metric or 0
    end,

    accessKeyAuth = function(conf, accessKey, chainType)
      -- Intercept requests
      if conf.ifCutReq then
        local cutChainType = conf.cutReqChainType
        if string.upper(chainType) == cutChainType then
          kong.log.info("cut accessKey: ", accessKey)
          kong.log.info("cut chainType: ", chainType)
          return kong.response.exit(503)
        end
      end

      local red, err = get_redis_connection(conf)
      if not red then
        kong.log.err("get_redis_connection err:",err)
        return nil, err
      end

      reports.retrieve_redis_version(red)

      local fullKey = get_full_key_name(conf, accessKey)
      kong.log.info("fullKey:", fullKey)

      local accesKeyInfo
      accesKeyInfo, err = red:get(fullKey)
      if err then
        kong.log.info("redis get userInfo err:", err)
        return nil, err
      end

      if accesKeyInfo == null or accesKeyInfo == nil then
        kong.log.info("accesKeyInfo is null, accesKeyInfo not exit")
        kong.response.set_header("grpc-status", "7")
        kong.response.set_header("grpc-message", "accessKey is incorrect")
        return kong.response.exit(401)
      end

      local info
      info, err = cjson.decode(accesKeyInfo)
      if err then
        kong.log.err("cjson.decode err:", err)
        return nil, err
      end

      if info == null or info == nil then
        kong.log.info("info is null")
        return nil, err
      end

      local status = info["status"]
      if status ~= 1 then
        return kong.response.exit(401)
      end

      local tps = info["tps"]
      -- kong.log.info("tps:", tps)
      local tpd = info["tpd"]
      -- kong.log.info("tpd:", tpd)
      
      if tps == -1 then
        tps = nil
      end

      if tpd == -1 then
        tpd = nil
      end

      if tps == -2 then
        local defaultConfig
        local defaultConfigFullKey
        defaultConfigFullKey = get_full_key_name(conf, "defaultConfig")
        defaultConfig, err = red:get(defaultConfigFullKey)
        if err then
          kong.log.err("redis get defaultConfigFullKey err:", err)
          return nil, err
        end
        if defaultConfig == null or defaultConfig == nil then
          kong.log.err("defaultConfig is null, defaultConfig not exit")
          tps = conf.second
        else
          local info, err = cjson.decode(defaultConfig)
          if err then
            kong.log.err("cjson.decode err:", err)
            return nil, err
          end
          local infoTps = info["tps"]
          if infoTps < 0 then
            tps = nil
          else
            tps = infoTps
          end
        end
      end

      if tpd == -2 then
        local defaultConfig
        local defaultConfigFullKey
        defaultConfigFullKey = get_full_key_name(conf, "defaultConfig")
        defaultConfig, err = red:get(defaultConfigFullKey)
        if err then
          kong.log.err("redis get defaultConfigFullKey err:", err)
          return nil, err
        end
        if defaultConfig == null or defaultConfig == nil then
          kong.log.err("defaultConfig is null, defaultConfig not exit")
          tpd = conf.day
        else
          local info, err = cjson.decode(defaultConfig)
          if err then
            kong.log.err("cjson.decode err:", err)
            return nil, err
          end
          local infoTpd = info["tpd"]
          if infoTpd < 0 then
            tpd = nil
          else
            tpd = infoTpd
          end
        end
      end

      info["tps"] = tps
      info["tpd"] = tpd

      local ok, err = red:set_keepalive(10000, 10000)
      if not ok or err then
        kong.log.err("failed to set Redis keepalive: ", err)
      end

      return info

    end

  }