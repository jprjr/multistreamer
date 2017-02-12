local ngx = ngx
local config = require'multistreamer.config'
local string = require'multistreamer.string'
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
local tonumber = tonumber

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
    local http_url = sa:get('http_url')

    if acc.network.get_view_count then
      insert(result.viewcounts, {
        account_id = acc.id,
        viewcount = acc.network.get_view_count(acc:get_all(),sa:get_all()),
        http_url = http_url,
        network = {
          name = acc.network.name,
          displayname = acc.network.displayname,
        }
      })
    end
  end

  publish('stream:viewcountresult',result)
end

function ChatMgr:createChatFuncs(stream, account, tarAccount, user, needRelay, shouldPublish)
  local sa = StreamAccount:find({stream_id = stream.id, account_id = tarAccount.id})

  if not self.streams[stream.id] then
    self.streams[stream.id] = {}
  end
  if not self.streams[stream.id][tarAccount.id] then
    self.streams[stream.id][tarAccount.id] = { aux = {} }
  end
  self.streams[stream.id][tarAccount.id].aux[account.id] = {}

  local relay
  if needRelay then
    relay = function(msg)
      msg.account_id = account.id
      msg.stream_id = stream.id
      msg.network = account.network.name
      publish('comment:in',msg)
    end
  end

  local read_func, write_func = account.network.create_comment_funcs(
    account:get_keystore():get_all(),
    sa:get_keystore():get_all(),
    relay
  )
  local t = {
    read_started = false,
    write_started = false,
    stream_id = stream.id,
    account_id = account.id,
    user_id = user.id,
    cur_stream_account_id = tarAccount.id,
  }
  if read_func then
    self.streams[stream.id][tarAccount.id].aux[account.id].read_thread = ngx.thread.spawn(read_func)
    t.read_started = true
  end
  if write_func then
    self.streams[stream.id][tarAccount.id].aux[account.id].send = write_func
    t.write_started = true
  end
  if shouldPublish then
    publish('stream:writerresult', t)
  end
  ngx.shared.writers:set(writer_id, to_json(t))
end

function ChatMgr:handleChatWriterRequest(msg)
  if msg.worker ~= ngx.worker.pid() then
    return nil
  end

  if not (msg.stream_id and msg.cur_stream_account_id and msg.account_id and msg.user_id) then
    return nil
  end

  msg.stream_id = tonumber(msg.stream_id)
  msg.cur_stream_account_id = tonumber(msg.cur_stream_account_id)
  msg.account_id = tonumber(msg.account_id)
  msg.user_id = tonumber(msg.user_id)

  local writer_id = msg.stream_id .. '-' .. msg.cur_stream_account_id .. '-' .. msg.account_id
  local writer_info_raw = ngx.shared.writers:get(writer_id)
  if writer_info_raw then
    local t = from_json(writer_info_raw)
    t.user_id = msg.user_id
    publish('stream:writerresult',t)
    return nil
  end

  local stream = Stream:find({id = msg.stream_id})
  local account = Account:find({id = msg.account_id})
  local tarAccount = Account:find({id = msg.cur_stream_account_id})
  local user = USer:find({id = msg.user_id})

  account.network = networks[account.network]

  self:createChatFuncs(stream,account,tarAccount,user,false,true)
end

function ChatMgr:handleStreamStart(msg)
  if msg.worker ~= ngx.worker.pid() then
    return nil
  end

  if not msg.id then
      return nil
  end

  msg.stream_id = tonumber(msg.id)

  local stream = Stream:find({id = msg.stream_id})
  local user = stream:get_user()

  local sas = stream:get_streams_accounts()
  StreamAccount:preload_relation(sas,"account")

  for _,sa in pairs(sas) do
    local acc = sa:get_account()
    acc.network = networks[acc.network]
    self:createChatFuncs(stream,acc,acc,user,true,false)
  end
end

function ChatMgr:handleCommentOut(msg)
  if not msg.stream_id or not msg.account_id or not msg.cur_stream_account_id then return end
  if self.streams[msg.stream_id] and
     self.streams[msg.stream_id][msg.cur_stream_account_id] and
     self.streams[msg.stream_id][msg.cur_stream_account_id].aux[msg.account_id] and
     self.streams[msg.stream_id][msg.cur_stream_account_id].aux[msg.account_id].send then
    self.streams[msg.stream_id][msg.cur_stream_account_id].aux[msg.account_id].send(msg.text)
  end
end

function ChatMgr:handleStreamEnd(msg)
  local stream = Stream:find({id = msg.id})
  if not stream then
    return nil
  end

  if self.streams[stream.id] then
    for k,v in pairs(self.streams[stream.id]) do -- k is account id
      if v then
        for i,j in pairs(v.aux) do
          if j and j.read_thread then
            ngx.thread.kill(j.read_thread)
          end
          ngx.shared.writers:set(stream.id .. '-' .. k .. '-' .. i, nil)
        end
      end
      self.streams[stream.id][k] = nil
    end
  end

  self.streams[stream.id] = nil
end

return ChatMgr
