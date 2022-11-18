local core = require "kong.plugins.access-key-auth-with-grpc.core"

local null = ngx.null
local kong = kong
local ngx = ngx
local time = ngx.time
local pairs = pairs
local error = error
local tostring = tostring
local timer_at = ngx.timer.at

local AccessKeyAuthWithGRPCHandler = {}

AccessKeyAuthWithGRPCHandler.PRIORITY = 98000
AccessKeyAuthWithGRPCHandler.VERSION = "1.0.0"

local function get_req_info(conf)
  local accessKey
  local chainType
  accessKey = kong.request.get_header(conf.accessKey_header_name)
  if accessKey == nil or accessKey == null then
    accessKey = kong.request.get_header("projectIdHeader")
  end
  if accessKey == "" then
    kong.log.info("accessKey is null")
    kong.response.set_header("grpc-status", "7")
		kong.response.set_header("grpc-message", "accessKey cannot be empty")
    return kong.response.exit(401)
  end
  chainType = kong.request.get_header(conf.chainType_header_name)
  if chainType == nil or chainType == null then
    chainType = kong.request.get_header("x-api-chain-type")
  end
  if chainType == "" then
    kong.log.info("chainType is null")
    kong.response.set_header("grpc-status", "7")
		kong.response.set_header("grpc-message", "chainType cannot be empty")
    return kong.response.exit(401)
  end
  local info,err = core.accessKeyAuth(conf,accessKey,chainType)
  if err then
    -- kong.log.info("accessKeyAuth err:", tostring(err))
    kong.response.set_header("grpc-status", "7")
		kong.response.set_header("grpc-message", "accessKey auth incorrect")
    return kong.response.exit(401)
  end

  if info == null or info == nil or info == "" then
    kong.log.info("info is nil:", tostring(err))
    kong.response.set_header("grpc-status", "7")
		kong.response.set_header("grpc-message", "accessKey auth incorrect")
    return kong.response.exit(401)
  end
  return accessKey,chainType, info
end


local function get_usage(conf, accessKey, current_timestamp, limits)
  local usage = {}
  local stop

  for period, limit in pairs(limits) do

    local current_usage, err = core.usage(conf, accessKey, period, current_timestamp)
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
  core.increment(conf, ...)
end


function AccessKeyAuthWithGRPCHandler:access(conf)

  local current_timestamp = time() * 1000

  local fault_tolerant = conf.fault_tolerant

  -- Consumer is identified by ip address or authenticated_credential id
  local accessKey, chainType, accessKeyInfo, err = get_req_info(conf)
  if err then
    if not fault_tolerant then
      return error(err)
    end
    kong.log.err("failed to get identifier: ", tostring(err))
    return kong.response.exit(401)
  end

  if chainType == null or chainType == nil then
    kong.log.err("chainType is null")
    return kong.response.error(401)
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

  local usage, stop, err = get_usage(conf, accessKey, current_timestamp, limits)
  if err then
    if not fault_tolerant then
      return error(err)
    end
    kong.log.err("failed to get usage: ", tostring(err))
    return kong.response.error(502)
  end
  if usage then
    -- If limit is exceeded, terminate the request
    if stop then
      return kong.response.error(429)
    end
  end

  local ok, err = timer_at(0, increment, conf, limits, accessKey, current_timestamp, 1)
  if not ok then
    kong.log.err("failed to create timer: ", err)
  end

  -- set_upstream
  local upstream = string.lower(chainType .. "-" .. "grpc")
  kong.service.set_upstream(upstream)

end


return AccessKeyAuthWithGRPCHandler
