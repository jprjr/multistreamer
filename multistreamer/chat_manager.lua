local ngx = ngx
local config = require'multistreamer.config'
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
local insert = table.insert

local ChatMgr = {}
ChatMgr.__index = ChatMgr

ChatMgr.new = function()
  local t = {}
  t.streams = {}
  t.messageFuncs = {
    [endpoint('stream:start')] = ChatMgr.handleStreamStart,
    [endpoint('stream:end')] = ChatMgr.handleStreamEnd,
    [endpoint('stream:writer')] = ChatMgr.handleChatWriterRequest,
    [endpoint('stream:viewcount')] = ChatMgr.handleViewCountRequest,
    [endpoint('comment:out')] = ChatMgr.handleCommentOut,
  }
  setmetatable(t,ChatMgr)
  return t
end

function ChatMgr:run()
  local running = true
  local ok, red = subscribe('stream:start')
  if not ok then
    ngx.log(ngx.ERR,'[Chat Manager] Unable to connect to redis: ' .. red)
    ngx.exit(ngx.ERROR)
  end
  subscribe('stream:end',red)
  subscribe('stream:writer',red)
  subscribe('stream:viewcount',red)
  subscribe('comment:out',red)
  while(running) do
    local res, err = red:read_reply()
    if err and err ~= 'timeout' then
      ngx.log(ngx.ERR,'[Chat Manager] Redis Disconnected!')
      ngx.exit(ngx.ERROR)
    end
    if res then
      local func = self.messageFuncs[res[2]]
      if func then
        func(self,from_json(res[3]))
      end
    end
  end
end

function ChatMgr:handleViewCountRequest(msg)
  if msg.worker ~= ngx.worker.pid() then
    return nil
  end

  local sas

  if msg.account_id then
    sas = { StreamAccount:find({ stream_id = msg.stream_id, account_id = msg.account_id }) }
  else
    sas = StreamAccount:select('where stream_id = ?', msg.stream_id)
  end
  StreamAccount:preload_relation(sas,'account')

  local result = {
    stream_id = msg.stream_id,
    viewcounts = {},
  }
  for i,sa in ipairs(sas) do
    local acc = sa:get_account()
    acc.network = networks[acc.network]

    if acc.network.get_view_count then
      insert(result.viewcounts, {
        account_id = acc.id,
        viewcount = acc.network.get_view_count(acc:get_all(),sa:get_all()),
        network = {
          name = acc.network.name,
          displayname = acc.network.displayname,
        }
      })
    end
  end

  publish('stream:viewcountresult',result)
end

function ChatMgr:handleChatWriterRequest(msg)
  if msg.worker ~= ngx.worker.pid() then
    return nil
  end
  local account = Account:find({id = msg.account_id})
  local sa = StreamAccount:find({stream_id = msg.stream_id, account_id = msg.cur_stream_account_id})

  account.network = networks[account.network]

  self.streams[msg.stream_id][account.id] = {}
  local read_func, write_func = account.network.create_comment_funcs(
    account:get_keystore():get_all(),
    sa:get_keystore():get_all()
  )
  local t = {
    read_started = false,
    write_started = false,
  }
  if read_func then
    self.streams[msg.stream_id][account.id].read_thread = ngx.thread.spawn(read_func)
    t.read_started = true
  end
  if write_func then
    self.streams[msg.stream_id][account.id].send = write_func
    t.write_started = true
  end
  publish('stream:writerresult', {
    stream_id = msg.stream_id,
    account_id = msg.account_id,
    user_id = msg.user_id,
    cur_stream_account_id = msg.cur_stream_account_id,
    read_started = t.read_started,
    write_started = t.write_started,
  })
end

function ChatMgr:handleStreamStart(msg)
  if msg.worker ~= ngx.worker.pid() then
    return nil
  end
  local stream = Stream:find({id = msg.id})
  if not stream then
    return nil
  end

  self.streams[stream.id] = {}
  local sas = stream:get_streams_accounts()
  StreamAccount:preload_relation(sas,"account")

  for _,sa in pairs(sas) do
    local acc = sa:get_account()
    acc.network = networks[acc.network]
    self.streams[stream.id][acc.id] = {}
    local function relay(msg)
      msg.account_id = acc.id
      msg.stream_id = stream.id
      msg.network = acc.network.name
      publish('comment:in',msg)
    end
    local read_func, write_func = acc.network.create_comment_funcs(
      acc:get_all(),
      sa:get_all(),
      relay)
    if read_func then
      self.streams[stream.id][acc.id].read_thread = ngx.thread.spawn(read_func)
    end
    if write_func then
      self.streams[stream.id][acc.id].send = write_func
    end
  end
end

function ChatMgr:handleCommentOut(msg)
  if not msg.stream_id or not msg.account_id then return end
  if self.streams[msg.stream_id] and
     self.streams[msg.stream_id][msg.account_id] and
     self.streams[msg.stream_id][msg.account_id].send then
   self.streams[msg.stream_id][msg.account_id].send(msg.text)
 end
end

function ChatMgr:handleStreamEnd(msg)
  local stream = Stream:find({id = msg.id})
  if not stream then
    return nil
  end

  if self.streams[stream.id] then
    for k,v in pairs(self.streams[stream.id]) do
      if v and v.read_thread then
        local ok, err = ngx.thread.kill(v.read_thread)
      end
      self.streams[stream.id][k] = nil
    end
  end

  self.streams[stream.id] = nil
end

return ChatMgr
