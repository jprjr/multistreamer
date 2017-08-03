-- luacheck: globals ngx networks uuid
local ngx = ngx
local networks = networks
local uuid = uuid

local from_json = require('lapis.util').from_json
local to_json = require('lapis.util').to_json
local ws_server = require'resty.websocket.server'
local slugify = require('lapis.util').slugify

local string = require'multistreamer.string'
local split = string.split
local escape_markdown = string.escape_markdown

local redis = require'multistreamer.redis'
local subscribe = redis.subscribe
local publish = redis.publish
local endpoint = redis.endpoint

local ngx_log = ngx.log
local ngx_eof = ngx.eof
local ngx_exit = ngx.exit
local ngx_error = ngx.ERROR
local ngx_debug = ngx.DEBUG
local ngx_err = ngx.ERR
local ngx_ok = ngx.OK

local now = ngx.now
local floor = math.floor

local setmetatable = setmetatable
local format = string.format
local pairs = pairs
local coro_status = coroutine.status
local kill = ngx.thread.kill
local spawn = ngx.thread.spawn
local streams = ngx.shared.streams

local concat = table.concat

local User = require'models.user'
local Stream = require'models.stream'
local StreamAccount = require'models.stream_account'
local Account = require'models.account'

local Server = {}
Server.__index = Server

local function add_account(l_networks,msg,accounts,account)
  if not accounts[account.id] and l_networks[account.network] then
    local id_string = format('%d',account.id)
    msg.accounts[id_string] = {
      network = {
        ['displayName'] = networks[account.network].displayname,
        ['name'] = account.network,
      },
      name = account.name,
      ready = false,
      live = false,
      writable = false,
    }
    if networks[account.network].write_comments then
      msg.accounts[id_string].writable = true
    end
  end
end

function Server.new(user, stream, chat_level)
  local t = {
    uuid = uuid(),
    user = user,
    stream = stream,
    chat_level = chat_level,
  }

  setmetatable(t,Server)
  return t
end

function Server:redis_relay()
  local running = true
  local ok, red = subscribe('comment:in')
  subscribe('stream:start', red);
  subscribe('stream:end', red);
  subscribe('stream:update', red);
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
      if res[2] == endpoint('comment:in') and
         not msg.relay and
         ( (msg.stream_id == self.stream.id) or (msg.to and (msg.to.id == self.user.id or msg.from.id == self.user.id)))
      then
        msg.uuid = nil
        self.ws:send_text(to_json(msg))
      elseif res[2] == endpoint('stream:start') and msg.id == self.stream.id then
        self:send_stream_status(msg.status)

      elseif res[2] == endpoint('stream:end') and msg.id == self.stream.id then
        self:send_stream_status({data_pushing = false, data_pulling = false, data_incoming = false })

      elseif res[2] == endpoint('stream:update') and msg.id == self.stream.id then
        self.stream = Stream:find({ id = msg.id })
      elseif res[2] == endpoint('stream:writerresult')
             and msg.stream_id == self.stream.id
             and msg.user_id == self.user.id then
        self.ws:send_text(to_json({
            ['type'] = 'writerresult',
            account_id = msg.account_id,
            cur_stream_account_id = msg.cur_stream_account_id,
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
      else
        ngx_log(ngx_debug,'[Websocket] sending ping')
        self.ws:send_ping('ping')
      end

    elseif typ == 'close' then
      self.ws:send_close()
      return true, nil

    elseif typ == 'pong' then
      ngx_log(ngx_debug,'[Websocket] received pong')

    elseif typ == 'text' then
      local msg = from_json(data)
      if msg.type == 'status' then
        local stream_status = streams:get(self.stream.id)
        if stream_status then
          stream_status = from_json(stream_status)
        else
          stream_status = {
              data_pushing = false,
              data_pulling = false,
              data_incoming = false
          }
        end
        self:send_stream_status(stream_status)
      elseif msg.type == 'text' or msg.type =='emote' then
        msg.stream_id = self.stream.id
        msg.uuid = self.uuid

        local parts = split(msg.text,' ')

        if parts[1] == '/irc' or parts[1] == '/msg' then
          msg.account_id = 0
          msg.text = concat(parts,' ', 2)
        end

        if msg.account_id == 0 then
          msg.from = {
            name = self.user.username,
            id = self.user.id,
          }
          msg.network = 'irc'
          msg.timestamp = floor(now() * 1000)

          if parts[1] == '/msg' then
            local un = parts[2]
            msg.text = concat(parts,' ',3)
            msg.stream_id = nil
            local u = User:find({ username = un })
            if u then
              msg.to = {
                name = u.username,
                id = u.id,
              }
              msg.markdown = escape_markdown(msg.text)
              publish('comment:in', msg)
            end
          else
            msg.markdown = escape_markdown(msg.text)
            publish('comment:in', msg)
          end
        else
          publish('comment:out', msg)
        end
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

function Server:send_stream_status(status)
  local msg = {
    ['type'] = 'status',
    ['accounts'] = {
      ['0'] = {
        network = {
          name = 'irc',
          displayName = 'IRC',
        },
        name = self.user.username,
        ready = true,
        live = false,
        writable = true,
      }
    }
  }

  msg.status = status

  if status.data_pushing == false then
    self.ws:send_text(to_json(msg))
    return
  end

  local l_networks = {}
  local accounts = self.stream:get_accounts()
  for id,v in pairs(accounts) do
    l_networks[v.network] = true
    local sa = StreamAccount:find({ stream_id = self.stream.id, account_id = id })
    local id_string = format('%d',id)
    msg.accounts[id_string] = {
      network = {
        ['name'] = v.network,
        ['displayName'] = networks[v.network].displayname,
      },
      name = v.name,
      ready = true,
      live = true,
      writable = false,
      http_url = sa:get('http_url'),
    }
    if networks[v.network].write_comments and self.chat_level == 2 then
      msg.accounts[id_string].writable = true
    end
  end

  local more_accounts = Account:select('where user_id = ?',self.user.id)
  if more_accounts then
    for _,v in ipairs(more_accounts) do
      add_account(l_networks,msg,accounts,v)
    end
  end

  local yet_more_accounts = self.user:get_shared_accounts()
  if yet_more_accounts then
    for _,sa in ipairs(yet_more_accounts) do
      local v = sa:get_account()
      add_account(l_networks,msg,accounts,v)
    end
  end

  self.ws:send_text(to_json(msg))
  return
end

function Server:run()
  local ws, err = ws_server:new({ timeout = 30000 })

  if err then
    ngx_log(ngx_err, 'websocket err ' .. err)
    ngx_eof()
    ngx_exit(ngx_error)
    return
  end

  self.ws = ws

  local stream_user = self.stream:get_user().username

  publish('irc:events:login', {
    nick = self.user.username,
    user_id = self.user.id,
    uuid = self.uuid,
    irc = false,
  })

  publish('irc:events:join', {
    nick = self.user.username,
    user_id = self.user.id,
    room = slugify(stream_user) .. '-' .. self.stream.slug,
    uuid = self.uuid,
  })

  local write_thread = spawn(Server.redis_relay,self)
  local read_thread  = spawn(Server.websocket_relay,self)

  ngx.thread.wait(write_thread,read_thread)

  if coro_status(write_thread) == 'running' then
    kill(write_thread)
  end

  if coro_status(read_thread) == 'running' then
    self.ws:send_close()
    kill(read_thread)
  end


  publish('irc:events:part', {
    nick = self.user.username,
    room = slugify(stream_user) .. '-' .. self.stream.slug,
    message = 'closed multistreamer chat',
    uuid = self.uuid,
  })

  publish('irc:events:logout', {
    nick = self.user.username,
    uuid = self.uuid,
  })

  ngx_eof()
  ngx_exit(ngx_ok)
end

return Server
