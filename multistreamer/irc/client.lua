local irc = require'multistreamer.irc'
local string = require'multistreamer.string'
local ngx = ngx
local char = string.char
local byte = string.byte
local setmetatable = setmetatable
local insert = table.insert
local pairs = pairs
local ipairs = ipairs
local unpack = unpack
if not unpack then
  unpack = table.unpack
end
local remove = table.remove
local concat = table.concat

local IRCClient = {}
IRCClient.__index = IRCClient

local function ircline(...)
  local line = irc.format_line(...)
  ngx.log(ngx.DEBUG,line)
  return line .. '\r\n'
end

local function ircline_forcecol(...)
  local args = {...}
  if args[#args]:find(' ') then
    return ircline(...)
  else
    args[#args] = ':' .. args[#args]
    return ircline(unpack(args))
  end
end

function IRCClient.new()
  local t = {}
  t.events = {}
  t.commandFuncs = {
    ['PING'] = IRCClient.serverPing,
    ['PRIVMSG'] = IRCClient.serverMessage,
  }
  setmetatable(t,IRCClient)
  return t
end

function IRCClient:onEvent(event,func)
  if(not self.events[event]) then
    self.events[event] = {}
  end
  insert(self.events[event],func)
  return true,nil
end

function IRCClient:delEvent(event,func)
  if not self.events[event] then return true, nil end
  local events = {}
  for i,ffunc in ipairs(self.events[event]) do
    if ffunc ~= func then
      insert(events,ffunc)
    end
  end
  self.events[event] = events
  return true,nil
end

function IRCClient:emitEvent(event,data)
  if not self.events[event] then return false, nil end
  for i,f in ipairs(self.events[event]) do
    f(event,data)
  end
  return true,nil
end

function IRCClient:connect(host,port)
  self.socket = ngx.socket.tcp()
  self.socket:settimeout(30000) -- crap out after 30 seconds
  local ok, err = self.socket:connect(host,port)
  if ok then
    self:emitEvent('connected')
    return true,nil
  end
  self:emitEvent('error',err)
  return false, err
end

function IRCClient:login(nickname,username,realname,password)
  self.nickname = nickname
  self.username = username
  self.realname = realname
  self.password = password

  if not self.nickname then
    return false, 'nickname is required'
  end

  if not self.username then
    self.username = self.nickname
  end

  if not self.realname then
    self.realname = self.nickname
  end

  local ok, err
  if self.password then
    ok, err = self.socket:send(ircline('PASS',self.password))
    if not ok then return false, err end
  end

  ok, err = self.socket:send(ircline('NICK',self.nickname))
  if not ok then return false, err end

  ok, err = self.socket:send(ircline_forcecol('USER',self.username,0,'*',self.realname))
  if not ok then return false, err end

  -- keep reading in lines until we see a '001' message
  local logging_in = true
  while(logging_in) do
    local data, err, partial = self.socket:receive('*l')
    if err then
      ngx.log(ngx.ERROR,err)
      self:emitEvent('error',err)
      return false, err
    end

    if data then
      ngx.log(ngx.DEBUG,data)
    end

    local msg = irc.parse_line(data)
    if msg.command == '001' then
      logging_in = false
    end
  end
  self:emitEvent('login')
  return true,nil
end

function IRCClient:join(room)
  local ok, err = self.socket:send(ircline('JOIN',room))
  if not ok then return false, err end
  return true, nil
end

function IRCClient:part(room,reason)
  if not reason then
    reason = 'Leaving'
  end
  local ok, err = self.socket:send(ircline_forcecol('PART',room,reason))
  if not ok then return false, err end
  return true,nil
end

function IRCClient:emote(room,msg)
  local msg = char(1)..'ACTION '..msg..char(1)
  return self:message(room,msg)
end

function IRCClient:message(room,msg)
  local ok, err = self.socket:send(ircline_forcecol('PRIVMSG',room,msg))
  if not ok then return false, err end
  return true,nil
end

function IRCClient:capreq(cap)
  local ok, err = self.socket:send(ircline_forcecol('CAP','REQ',cap))
  if not ok then return false, err end
  return true,nil
end


function IRCClient:cruise()
  local running = true
  while running do
    local data, err, partial = self.socket:receive('*l')
    if err and err ~= 'timeout' then
      return false, err
    end
    local msg
    if data then
      ngx.log(ngx.DEBUG,data)
      msg = irc.parse_line(data)
    else
      msg = irc.parse_line(partial)
    end
    if msg and msg.command then
      local func = self.commandFuncs[msg.command:upper()]
      if func then func(self,msg) end
    end
  end
end

function IRCClient:serverPing(msg)
  self.socket:send(ircline('PONG',msg.args[1]))
end

function IRCClient:serverMessage(msg)
  if msg.args[2]:byte(1) == 1 then
    local message = msg.args[2]:sub(2,msg.args[2]:len()-1)
    local parts = message:split(' ')
    if parts[1] == 'ACTION' then
      self:emitEvent('emote',{
        from = msg.from,
        to = msg.args[1],
        message = concat(parts,' ',2),
        tags = msg.tags,
      })
    end
  else
    self:emitEvent('message',{
      from = msg.from,
      to = msg.args[1],
      message = msg.args[2],
      tags = msg.tags,
    })
  end
end


return IRCClient
