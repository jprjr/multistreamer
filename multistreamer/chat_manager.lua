-- luacheck: globals ngx networks
local ngx = ngx
local networks = networks

local redis = require'multistreamer.redis'
local endpoint = redis.endpoint
local publish = redis.publish
local subscribe = redis.subscribe
local from_json = require('lapis.util').from_json
local to_json = require('lapis.util').to_json
local Stream = require'models.stream'
local Account = require'models.account'
local StreamAccount = require'models.stream_account'
local setmetatable = setmetatable
local tonumber = tonumber
local pairs = pairs

local ngx_err = ngx.ERR
local ngx_error = ngx.ERROR
local ngx_log = ngx.log
local ngx_exit = ngx.exit
local writers = ngx.shared.writers
local pid = ngx.worker.pid()
local spawn = ngx.thread.spawn
local status_dict = ngx.shared.status;
local floor = math.floor
local now = ngx.now

local ChatMgr = {}
ChatMgr.__index = ChatMgr

ChatMgr.new = function()
  local t = {}
  t.streams = {}
  t.messageFuncs = {
    [endpoint('stream:start')] = ChatMgr.handleStreamStart,
    [endpoint('stream:end')] = ChatMgr.handleStreamEnd,
    [endpoint('stream:writer')] = ChatMgr.handleChatWriterRequest,
    [endpoint('comment:out')] = ChatMgr.handleCommentOut,
  }
  setmetatable(t,ChatMgr)
  return t
end

function ChatMgr:run()
  local running = true
  local ok, red = subscribe('stream:start')
  if not ok then
    ngx_log(ngx_err,'[Chat Manager] Unable to connect to redis: ' .. red)
    status_dict:set('chatmgr_error',true)
    ngx_exit(ngx_error)
  end
  subscribe('stream:end',red)
  subscribe('stream:writer',red)
  subscribe('stream:viewcount',red)
  subscribe('comment:out',red)
  while(running) do
    local res, err = red:read_reply()
    if err and err ~= 'timeout' then
      ngx_log(ngx_err,'[Chat Manager] Redis Disconnected!')
      ngx_exit(ngx_error)
    end
    if res then
      local func = self.messageFuncs[res[2]]
      if func then
        func(self,from_json(res[3]))
      end
    end
  end
end

function ChatMgr:createChatFuncs(stream,account,tarAccount,relay)
  local t = {
    read_started = false,
    write_started = false,
    stream_id = stream.id,
    account_id = account.id,
    cur_stream_account_id = tarAccount.id,
  }

  local sa = StreamAccount:find({stream_id = stream.id, account_id = tarAccount.id})

  if not self.streams[stream.id] then
    self.streams[stream.id] = {}
  end

  if not self.streams[stream.id][tarAccount.id] then
    self.streams[stream.id][tarAccount.id] = { aux = {} }
  end

  if not self.streams[stream.id][tarAccount.id].aux[account.id] then
    self.streams[stream.id][tarAccount.id].aux[account.id] = {}
  end

  local read_func, write_func, stop_func = networks[account.network].create_comment_funcs(
    account:get_keystore():get_all(),
    sa:get_keystore():get_all(),
    relay
  )

  local viewcount_func, stop_viewcount_func = networks[account.network].create_viewcount_func(
    account:get_keystore():get_all(),
    sa:get_keystore():get_all(),
    function(data)
      data.stream_id = stream.id
      data.account_id = account.id
      publish('stream:viewcountresult',data)
  end)

  if read_func then
    self.streams[stream.id][tarAccount.id].aux[account.id].read_thread = spawn(function()
      local _, err = read_func()
      if err then
        ngx_log(ngx_err,err)
      end
    end)
    t.read_started = true
  end

  if write_func then
    self.streams[stream.id][tarAccount.id].aux[account.id].send = write_func
    t.write_started = true
  end

  if stop_func then
    self.streams[stream.id][tarAccount.id].aux[account.id].stop = stop_func
  end

  if viewcount_func then
    self.streams[stream.id][tarAccount.id].aux[account.id].viewcount_thread = spawn(viewcount_func)
  end

  if stop_viewcount_func then
    self.streams[stream.id][tarAccount.id].aux[account.id].stop_viewcount = stop_viewcount_func
  end

  writers:set(stream.id .. '-' .. tarAccount.id .. '-' .. account.id, to_json(t))

  return t
end

function ChatMgr:handleChatWriterRequest(msg)
  if msg.worker ~= pid then
    return nil
  end

  if not (msg.stream_id and msg.cur_stream_account_id and msg.account_id and msg.user_id) then
    return nil
  end

  msg.stream_id = tonumber(msg.stream_id)
  msg.cur_stream_account_id = tonumber(msg.cur_stream_account_id)
  msg.account_id = tonumber(msg.account_id)
  msg.user_id = tonumber(msg.user_id)

  -- check if there's a writer already running
  local writer_id = msg.stream_id .. '-' .. msg.cur_stream_account_id .. '-' .. msg.account_id
  local writer_info_raw = writers:get(writer_id)
  if writer_info_raw then
    local t = from_json(writer_info_raw)
    t.user_id = msg.user_id
    publish('stream:writerresult',t)
    return nil
  end

  local stream = Stream:find({ id = msg.stream_id })
  local account = Account:find({id = msg.account_id})
  local tarAccount = Account:find({ id = msg.cur_stream_account_id })

  local t = self:createChatFuncs(stream,account,tarAccount)

  t.user_id = msg.user_id

  publish('stream:writerresult', t)
end

function ChatMgr:handleStreamStart(msg)
  if msg.worker ~= pid then
    return nil
  end
  if msg.status.data_pushing ~= true then
    return nil
  end
  local stream = Stream:find({id = msg.id})

  if not stream then
    return nil
  end

  local sas = stream:get_streams_accounts()
  StreamAccount:preload_relation(sas,"account")

  for _,sa in pairs(sas) do
    local account = sa:get_account()

    local function relay(_msg)
      _msg.account_id = account.id
      _msg.stream_id = stream.id
      _msg.network = networks[account.network].name
      if not _msg.timestamp then
        _msg.timestamp = floor(now() * 1000)

      end
      publish('comment:in',_msg)
      for _,v in pairs(stream:get_webhooks()) do
        v:fire_event('comment:in',_msg)
      end
    end

    local t = self:createChatFuncs(stream,account,account,relay)
    local writer_id = stream.id .. '-' .. account.id .. '-' .. account.id

    writers:set(writer_id, to_json(t))
  end
end

function ChatMgr:handleCommentOut(msg)
  if not msg.stream_id or not msg.account_id or not msg.cur_stream_account_id then return end

  if self.streams[msg.stream_id] and
     self.streams[msg.stream_id][msg.cur_stream_account_id] and
     self.streams[msg.stream_id][msg.cur_stream_account_id].aux[msg.account_id] and
     self.streams[msg.stream_id][msg.cur_stream_account_id].aux[msg.account_id].send then
    self.streams[msg.stream_id][msg.cur_stream_account_id].aux[msg.account_id].send(msg)
  end
end

function ChatMgr:handleStreamEnd(msg)
  local stream = Stream:find({id = msg.id})
  if not stream then
    return nil
  end

-- note: self.streams[stream.id][tarAccount.id].aux[account.id].read_thread = spawn(function()
  if self.streams[stream.id] then
    for k,v in pairs(self.streams[stream.id]) do -- k is tarAccount.id
      if v then
        for i,j in pairs(v.aux) do
          if j then
            if j.stop then
              j.stop()
            end
            if j.stop_viewcount then
              j.stop_viewcount()
            end
          end
          j.send = nil
          writers:set(stream.id .. '-' .. k .. '-' .. i, nil)
        end
      end
      self.streams[stream.id][k] = nil
    end
  end

  self.streams[stream.id] = nil
end

return ChatMgr
