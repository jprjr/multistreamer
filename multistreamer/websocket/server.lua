local from_json = require('lapis.util').from_json
local to_json = require('lapis.util').to_json
local ws_server = require'resty.websocket.server'

local redis = require'multistreamer.redis'
local subscribe = redis.subscribe
local publish = redis.publish
local endpoint = redis.endpoint

local StreamAccount = require'models.stream_account'
local Account = require'models.account'

local Server = {}
Server.__index = Server

function Server:new(user, stream)
  local t = {}
  t.user = user
  t.stream = stream

  setmetatable(t,Server)
  return t
end

function Server:redis_relay()
  local running = true
  local ok, red = subscribe('comment:in')
  subscribe('stream:start', red);
  subscribe('stream:end', red);
  subscribe('stream:writerresult', red);
  subscribe('stream:viewcountresult', red);

  if not ok then
    running = false
  end

  while(running) do
    local res, err = red:read_reply()

    if err and err ~= 'timeout' then
      self.ws:send_close()
      return nil, err
    end

    if res then
      local msg = from_json(res[3])
      if res[2] == endpoint('comment:in') and msg.stream_id == self.stream.id then
        self.ws:send_text(res[3])
      elseif res[2] == endpoint('stream:start') and msg.id == self.stream.id then
        self:send_stream_status(true)
      elseif res[2] == endpoint('stream:end') and msg.id == self.stream.id then
        self:send_stream_status(false)
      elseif res[2] == endpoint('stream:writerresult') and msg.stream_id == self.stream.id then
        self.ws:send_text(to_json({
            ['type'] = 'writerresult',
            account_id = msg.account_id,
        }))
      elseif res[2] == endpoint('stream:viewcountresult') and msg.stream_id == self.stream.id then
        msg['type'] = 'viewcountresult'
        self.ws:send_text(to_json(msg))
      end
    end
  end

  return true, nil

end

function Server:websocket_relay()
  local running = true

  while(running) do
    local data, typ, err = self.ws:recv_frame()

    if not data and not typ then
      if self.ws.fatal then
        return nil, err
      end

    elseif typ == 'close' then
      self.ws:send_close()
      return true, nil

    elseif typ == 'ping' then
      self.ws:send_pong(data)

    elseif typ == 'text' then
      local msg = from_json(data)
      if msg.type == 'status' then
        local ok = ngx.shared.streams:get(self.stream.id)
        if not ok then
            ok = false
        end
        self:send_stream_status(ok)
      elseif msg.type == 'comment' then
        publish('comment:out', {
          stream_id = self.stream.id,
          account_id = msg.account_id,
          text = msg.text,
        })
      elseif msg.type == 'viewcount' then
        publish('stream:viewcount', {
            worker = ngx.worker.pid(),
            stream_id = self.stream.id,
        })
      elseif msg.type == 'writer' then
        publish('stream:writer', {
            worker = ngx.worker.pid(),
            account_id = msg.account_id,
            user_id = self.user.id,
            stream_id = self.stream.id,
            cur_stream_account_id = msg.cur_stream_account_id,
        })
      end
    end
  end
  return true, nil
end

function Server:send_stream_status(ok)
  local msg = {
    ['type'] = 'status'
  }
  if not ok then
    msg.status = 'end'
    self.ws:send_text(to_json(msg))
    return
  end
  msg.status = 'live'
  msg.accounts = {}

  local l_networks = {}
  local accounts = self.stream:get_accounts()
  for id,v in pairs(accounts) do
    l_networks[v.network] = true
    local sa = StreamAccount:find({ stream_id = self.stream.id, account_id = id })
    local id_string = string.format('%d',id)
    msg.accounts[id_string] = {
      network = v.network,
      name = v.name,
      http_url = sa:get('http_url'),
      ready = true,
      live = true,
      writable = false,
    }
    if networks[v.network].write_comments then
      msg.accounts[id_string].writable = true
    end
  end

  local more_accounts = Account:select('where user_id = ?',self.user.id)
  if more_accounts then
  for i,v in ipairs(more_accounts) do
    if not accounts[v.id] and l_networks[v.network] then
      local id_string = string.format('%d',v.id)
      msg.accounts[id_string] = {
        network = v.network,
        name = v.name,
        ready = false,
        live = false,
        writable = false,
      }
      if networks[v.network].write_comments then
        msg.accounts[id_string].writable = true
      end
    end
  end
  end

  self.ws:send_text(to_json(msg))
  return
end

function Server:run()
  local ws, err = ws_server:new()

  if err then
    ngx.log(ngx.ERR, 'websocket err ' .. err)
    ngx.eof()
    ngx.exit(ngx.ERROR)
    return
  end

  self.ws = ws

  local write_thread = ngx.thread.spawn(Server.redis_relay,self)
  local read_thread = ngx.thread.spawn(Server.websocket_relay,self)

  local ok, write_res, read_res = ngx.thread.wait(write_thread,read_thread)
  if coroutine.status(write_thread) == 'running' then
    ngx.thread.kill(write_thread)
  end
  if coroutine.status(read_thread) == 'running' then
    ngx.thread.kill(read_thread)
  end

  self.ws:send_close()

  ngx.eof()
  ngx.exit(ngx.OK)
end

return Server
