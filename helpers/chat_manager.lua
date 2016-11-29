local ngx = ngx
local redis = require'resty.redis'
local config = require('lapis.config').get()
local from_json = require('lapis.util').from_json
local to_json = require('lapis.util').to_json
local Stream = require'models.stream'
local setmetatable = setmetatable

if not config.redis_prefix or string.len(config.redis_prefix) == 0 then
  config.redis_prefix = 'multistreamer/'
end

local function redis_publish(endpoint,message)
  local red = redis.new()
  local ok, err = red:connect(config.redis_host)
  if not ok then
    ngx.log(ngx.ERR,'[Chat Manager] Unable to connect to redis: ' .. err)
    return false, err
  end
  local ok, err = red:publish(config.redis_prefix .. endpoint, to_json(message))
  if not ok then return false, err end
  return true, nil
end

local function redis_subscribe(endpoint,red)
  local red = red
  if not red then
    red = redis.new()
    local ok, err = red:connect(config.redis_host)
    if not ok then
      ngx.log(ngx.ERR,'[Chat Manager] Unable to connect to redis: ' .. err)
      return false, err
    end
  end
  local ok, err = red:subscribe(config.redis_prefix .. endpoint)
  if not ok then return false, err end
  return true, red
end

local ChatMgr = {}
ChatMgr.__index = ChatMgr

ChatMgr.new = function()
  local t = {}
  t.streams = {}
  setmetatable(t,ChatMgr)
  return t
end

function ChatMgr:run()
  local running = true
  local ok, red = redis_subscribe('streams')
  if not ok then
    ngx.log(ngx.ERR,'[Chat Manager] Unable to connect to redis: ' .. red)
    ngx.exit(ngx.ERROR)
  end
  while(running) do
    local res, err = red:read_reply()
    if err and err ~= 'timeout' then
      ngx.log(ngx.ERR,'[Chat Manager] Redis Disconnected!')
      ngx.exit(ngx.ERROR)
    end
    if res then self:routeMessage(res) end
  end
end

function ChatMgr:routeMessage(msg)
  if msg[2] == config.redis_prefix .. 'streams' then
    self:handleStreamUpdate(from_json(msg[3]))
  end
end

function ChatMgr:handleStreamUpdate(msg)
  if msg.status == 'live' or msg.status == 'stopped' then
    if msg.worker ~= ngx.worker.pid() then
      return nil
    end
    local stream = Stream:find({id = msg.id})
    if not stream then return nil end

    if msg.status == 'live' then
      self.streams[msg.id] = {}

      for _,sa in pairs(stream:get_streams_accounts()) do
        local acc = sa:get_account()
        acc.network = networks[acc.network]
        self.streams[msg.id][acc.id] = {}
        local function relay(msg)
          msg.account_id = acc.id
          msg.stream_id = stream.id
          redis_publish('comments',msg)
        end
        local read_func, write_func = acc.network.create_comment_funcs(
          acc:get_keystore(),
          sa:get_keystore(),
          relay)
        if read_func then
          self.streams[msg.id][acc.id].read_thread = ngx.thread.spawn(read_func)
        end
        if write_func then
          self.streams[msg.id][acc.id].send = write_func
        end
      end
    elseif msg.status == 'stopped' then
      for _,sa in pairs(stream:get_streams_accounts()) do
        local acc = sa:get_account()

        if self.streams[msg.id] and self.streams[msg.id][acc.id] then
          if self.streams[msg.id][acc.id].read_thread then
            local ok, err = ngx.thread.kill(self.streams[msg.id][acc.id].read_thread)
          end
          self.streams[msg.id][acc.id] = nil
        end
      end
      self.streams[msg.id] = nil
    end
  end
end

return ChatMgr
