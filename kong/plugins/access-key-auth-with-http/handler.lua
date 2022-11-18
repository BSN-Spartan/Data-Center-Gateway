-- Copyright (C) Kong Inc.
local timestamp = require "kong.tools.timestamp"
local policies = require "kong.plugins.access-key-auth-with-http.policies"

local null = ngx.null
local kong = kong
local ngx = ngx
local max = math.max
local time = ngx.time
local floor = math.floor
local pairs = pairs
local error = error
local tostring = tostring
local timer_at = ngx.timer.at


local EMPTY = {}
local EXPIRATION = require "kong.plugins.access-key-auth-with-http.expiration"


local RATELIMIT_LIMIT     = "RateLimit-Limit"
local RATELIMIT_REMAINING = "RateLimit-Remaining"
local RATELIMIT_RESET     = "RateLimit-Reset"
local RETRY_AFTER         = "Retry-After"


local X_RATELIMIT_LIMIT = {
  second = "X-RateLimit-Limit-Second",
  minute = "X-RateLimit-Limit-Minute",
  hour   = "X-RateLimit-Limit-Hour",
  day    = "X-RateLimit-Limit-Day",
  month  = "X-RateLimit-Limit-Month",
  year   = "X-RateLimit-Limit-Year",
}

local X_RATELIMIT_REMAINING = {
  second = "X-RateLimit-Remaining-Second",
  minute = "X-RateLimit-Remaining-Minute",
  hour   = "X-RateLimit-Remaining-Hour",
  day    = "X-RateLimit-Remaining-Day",
  month  = "X-RateLimit-Remaining-Month",
  year   = "X-RateLimit-Remaining-Year",
}


local RateLimitingHandler = {}


RateLimitingHandler.PRIORITY = 99000
RateLimitingHandler.VERSION = "1.1.0"


local function get_identifier(conf)
  local identifier
  local accessKeyInfo

  if conf.limit_by == "service" then
    identifier = (kong.router.get_service() or
                  EMPTY).id
  elseif conf.limit_by == "consumer" then
    identifier = (kong.client.get_consumer() or
                  kong.client.get_credential() or
                  EMPTY).id

  elseif conf.limit_by == "credential" then
    identifier = (kong.client.get_credential() or
                  EMPTY).id

  elseif conf.limit_by == "header" then
    identifier = kong.request.get_header(conf.header_name)

  elseif conf.limit_by == "path" then
    --if req_path == conf.path then
    --  identifier = req_path
    local uInfo, err = policies[conf.policy].accessKeyAuth(conf)
    if err then
      kong.log.err("accessKeyAuth err:", tostring(err))
      return nil,nil, err
    end
    if uInfo == null or uInfo == nil or uInfo == "" then
      kong.log.err("uInfo is nil:", tostring(err))
      return nil,nil, err
    end
    identifier = uInfo["accessKey"]
    accessKeyInfo = uInfo

  end
  -- return identifier or kong.client.get_forwarded_ip(), bsnUserInfo
  return identifier, accessKeyInfo
end


local function get_usage(conf, identifier, current_timestamp, limits)
  local usage = {}
  local stop

  for period, limit in pairs(limits) do

    local current_usage, err = policies[conf.policy].usage(conf, identifier, period, current_timestamp)
    if err then
      return nil, nil, err
    end

    -- What is the current usage for the configured limit name?
    local remaining = limit - current_usage

    -- Recording usage
    usage[period] = {
      limit = limit,
      remaining = remaining,
    }

    if remaining <= 0 then
      stop = period
    end
  end

  return usage, stop
end


local function increment(premature, conf, ...)
  if premature then
    return
  end

  policies[conf.policy].increment(conf, ...)
end


function RateLimitingHandler:access(conf)

  local current_timestamp = time() * 1000

  local fault_tolerant = conf.fault_tolerant

  -- Consumer is identified by ip address or authenticated_credential id
  local identifier, accessKeyInfo, err = get_identifier(conf)
  if err then
    if not fault_tolerant then
      return error(err)
    end
    kong.log.err("failed to get identifier: ", tostring(err))
    return kong.response.error(401, "UNAUTHORIZED: please check the project config")
  end

  if identifier == null or identifier == nil then
    kong.log.err("identifier is null")
    return kong.response.error(401, "UNAUTHORIZED: please check the project config")
  end


  local tps = accessKeyInfo["tps"]
  -- kong.log.info("tps:", tps)
  local tpd = accessKeyInfo["tpd"]
  -- kong.log.info("tpd:", tpd)

  -- Load current metric for configured period
  local limits = {
    second = tps,
    minute = conf.minute,
    hour = conf.hour,
    day = tpd,
    month = conf.month,
    year = conf.year,
  }

  local usage, stop, err = get_usage(conf, identifier, current_timestamp, limits)
  if err then
    if not fault_tolerant then
      return error(err)
    end
    kong.log.err("failed to get usage: ", tostring(err))
    return kong.response.error(502, "Gateway error")
  end
  if usage then
    -- Adding headers
    local reset
    local headers
    if not conf.hide_client_headers then
      headers = {}
      local timestamps
      local limit
      local window
      local remaining
      for k, v in pairs(usage) do
        local current_limit = v.limit
        local current_window = EXPIRATION[k]
        local current_remaining = v.remaining
        if stop == nil or stop == k then
          current_remaining = current_remaining - 1
        end
        current_remaining = max(0, current_remaining)
        if not limit or (current_remaining < remaining)
                    or (current_remaining == remaining and
                        current_window > window)
        then
          limit = current_limit
          window = current_window
          remaining = current_remaining
          if not timestamps then
            timestamps = timestamp.get_timestamps(current_timestamp)
          end
          reset = max(1, window - floor((current_timestamp - timestamps[k]) / 1000))
        end
        headers[X_RATELIMIT_LIMIT[k]] = current_limit
        headers[X_RATELIMIT_REMAINING[k]] = current_remaining
      end
      headers[RATELIMIT_LIMIT] = limit
      headers[RATELIMIT_REMAINING] = remaining
      headers[RATELIMIT_RESET] = reset
    end
    -- If limit is exceeded, terminate the request
    if stop then
      headers = headers or {}
      headers[RETRY_AFTER] = reset
      return kong.response.error(429, "Reaches the request limit", headers)
    end
    if headers then
      kong.response.set_headers(headers)
    end
  end

  -- set_path
  -- kong.log.info("lastPath: ", accessKeyInfo["lastPath"])
  kong.service.request.set_path(accessKeyInfo["lastPath"])

  -- set_raw_query
  local params = kong.request.get_raw_query()
  kong.service.request.set_raw_query(params)

  local ok, err = timer_at(0, increment, conf, limits, identifier, current_timestamp, 1)
  if not ok then
    kong.log.err("failed to create timer: ", err)
  end

  -- set_upstream
  -- kong.log.info("upstream: ", accessKeyInfo["upstream"])
  kong.service.set_upstream(accessKeyInfo["upstream"])

end


return RateLimitingHandler
