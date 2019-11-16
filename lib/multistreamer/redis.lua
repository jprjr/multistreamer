-- luacheck: globals ngx
local ngx = ngx
local config = require'multistreamer.config'.get()
local redis = require'resty.redis'
local to_json = require('lapis.util').to_json
local format = string.format

local ngx_log_o = ngx.log
local ngx_err = ngx.ERR
local ngx_debug = ngx.DEBUG

local function ngx_log(lvl, msg)
  if lvl ~= ngx_debug then
    ngx_log_o(lvl,msg)
  elseif config.redis_debug then
    ngx_log_o(lvl,msg)
  end
end

local M = {}

M.endpoint = function(point)
  return config.redis_prefix .. point
end

M.publish = function(point,message)
  local red = redis.new()
  local ok, err = red:connect(config.redis_host,config.redis_port)

  if not ok then
    ngx_log(ngx_err,format('Redis:publish: unable to connect to redis: %s:%s %s',config.redis_host,config.redis_port,err))
    return false, err
  end

  ngx_log(ngx_debug,format('Redis:publish: [%s] %s',point,to_json(message)))

  local pub_ok, pub_err = red:publish(M.endpoint(point), to_json(message))
  if not pub_ok then return false, pub_err end
  return true, nil
end

M.subscribe = function(point,red)
  if not red then
    red = redis.new()
    local ok, err = red:connect(config.redis_host,config.redis_port)
    if not ok then
      ngx_log(ngx_err,format('Redis:subscribe: Unable to connect to redis: %s:%s %s',config.redis_host,config.redis_port,err))
      return false, err
    end
  end
  local ok, err = red:subscribe(M.endpoint(point))
  if not ok then return false, err end
  return true, red
end

return M
