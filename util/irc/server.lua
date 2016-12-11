local irc = require'util.irc'
local config = require'helpers.config'
local date = require'date'
local slugify = require('lapis.util').slugify
local to_json = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local User = require'models.user'
local Stream = require'models.stream'
local Account = require'models.account'
local string = require'util.string'

local insert = table.insert
local remove = table.remove
local char = string.char
local find = string.find
local len = string.len
local sub = string.sub
local unpack = unpack
if not unpack then
  unpack = table.unpack
end
local networks = networks

local redis = require'helpers.redis'
local endpoint = redis.endpoint
local publish = redis.publish
local subscribe = redis.subscribe

local IRCServer = {}
IRCServer.__index = IRCServer

function botPublish(nick,room,message)
  publish('irc:events:message', {
    nick = 'root',
    target = '#'..room,
    message = nick .. ': ' .. message
  })
end

function IRCServer.new(socket,user,parentServer)
  local server = {}
  server.ready = false
  if parentServer then
    curState = parentServer:getState()
    server.socket = socket
    server.user = user
    server.rooms = curState.rooms
    server.users = curState.users
    server.users[user.nick] = {}
    server.users[user.nick].user = user
    server.users[user.nick].socket = socket

    publish('irc:events:login', {
      nick = user.nick,
      username = user.username,
      realname = user.realname,
      id = user.id,
    })
  else
    server.rooms = {}
    server.users = {
      root = {
        user = {
            nick = 'root',
            username = 'root',
            realname = 'root',
            id = 0,
        }
      }
    }
  end

  server.clientFunctions = {
    ['LIST'] = IRCServer.clientList,
    ['JOIN'] = IRCServer.clientJoinRoom,
    ['PART'] = IRCServer.clientPartRoom,
    ['PING'] = IRCServer.clientPing,
    ['PRIVMSG'] = IRCServer.clientMessage,
    ['MODE'] = IRCServer.clientMode,
    ['QUIT'] = IRCServer.clientQuit,
    ['WHO'] = IRCServer.clientWho,
    ['WHOIS'] = IRCServer.clientWhois,
  }
  server.redisFunctions = {
    [endpoint('stream:start')] = IRCServer.processStreamStart,
    [endpoint('stream:end')] = IRCServer.processStreamEnd,
    [endpoint('stream:update')] = IRCServer.processStreamUpdate,
    [endpoint('stream:writer:result')] = IRCServer.processWriterResult,
    [endpoint('comment:in')] = IRCServer.processCommentUpdate,
    [endpoint('irc:events:login')] = IRCServer.processIrcLogin,
    [endpoint('irc:events:logout')] = IRCServer.processIrcLogout,
    [endpoint('irc:events:join')] = IRCServer.processIrcJoin,
    [endpoint('irc:events:part')] = IRCServer.processIrcPart,
    [endpoint('irc:events:message')] = IRCServer.processIrcMessage,
  }
  server.botCommands = {
    ['help'] = {
      func = IRCServer.botCommandHelp,
      help = {'Usage: !help <command> '},
    },
    ['summon'] = {
      func = IRCServer.botCommandSummon,
      help = {
        'Usage: !summon <existing room bot>',
        '^ List what accounts you can create a bot for',
        '!summon <existing room bot> <your account>',
        '^ Create a bot to post as your account',
      },
    },
  }
  setmetatable(server,IRCServer)
  return server
end

function IRCServer:run()
  local running = true

  local ok, red = subscribe('irc:events:login')
  if not ok then
    ngx.exit(ngx.ERROR)
  end
  subscribe('irc:events:logout',red)
  subscribe('irc:events:join',red)
  subscribe('irc:events:part',red)
  subscribe('irc:events:message',red)
  subscribe('stream:start',red)
  subscribe('stream:end',red)
  subscribe('stream:update',red)
  subscribe('comment:in',red)
  subscribe('stream:writer:result',red)

  self.ready = true

  local red_func = ngx.thread.spawn(function()
    while true do
      local res, err = red:read_reply()
      if err and err ~= 'timeout' then
        ngx.log(ngx.ERR,'[IRC] Redis disconnected!')
        self.ready = false
        return false
      end
      if res then
        local func = self.redisFunctions[res[2]]
        if func then
          func(self,from_json(res[3]))
        end
      end
    end
  end)
  if self.socket then
    local irc_func = ngx.thread.spawn(function()
      while true do
        if not self.socket then return end
        local data, err, partial = self.socket:receive('*l')
        local msg
        if data then
          ngx.log(ngx.DEBUG,data)
          msg = irc.parse_line(data)
        elseif partial then
          ngx.log(ngx.DEBUG,partial)
          msg = irc.parse_line(partial)
        end
        if err and err == 'closed' then
          return
        end
        if not err or err ~= 'timeout' then
          local ok, err = self:processClientMessage(self.user.nick,msg)
          if not ok then
            ngx.log(ngx.ERR,'[IRC] ' .. err)
            return
          end
        end
      end
    end)
    local ok, irc_res, red_res = ngx.thread.wait(irc_func,red_func)
    if coroutine.status(red_func) == 'dead' then
      ngx.thread.kill(irc_func)
    else
      ngx.thread.kill(red_func)
    end
    self:endClient(self.user)
  else
    for _,u in ipairs(User:select()) do
      for _,s in ipairs(u:get_streams()) do
        local room = slugify(u.username)..'-'..s.slug
        self.rooms[room] = {
          user_id = u.id,
          stream_id = s.id,
          users = {
            root = true,
          },
          topic = 'Status: offline',
          mtime = date.diff(s.updated_at,date.epoch()):spanseconds(),
          ctime = date.diff(s.created_at,date.epoch()):spanseconds(),
        }
      end
    end
    local ok, res = ngx.thread.wait(red_func)
    if res == false then
      ngx.exit(ngx.ERROR)
    end
    ngx.exit(ngx.OK)
  end
end

function IRCServer:getState()
  return {
    users = from_json(to_json(self.users)),
    rooms = from_json(to_json(self.rooms)),
  }
end

function IRCServer:processWriterResult(update)
  local stream = Stream:find({ id = update.stream_id })
  local account = Account:find({ id = update.account_id })
  local og_account = Account:find({ id = update.cur_stream_account_id })
  account.network = networks[account.network]
  local accountUsername = slugify(account.network.name) .. '-' .. account.slug .. '-' .. og_account.slug
  local roomName = slugify(account:get_user().username) .. '-' .. stream.slug
  self.users[accountUsername] = {
    user = {
      nick = accountUsername,
      username = accountUsername,
      realname = accountUsername,
    },
    account_id = account.id,
    network = account.network,
  }
  self.rooms[roomName].users[accountUsername] = true
  for u,user in pairs(self.rooms[roomName].users) do
    if self.users[u].socket then
      self:sendRoomJoin(u,accountUsername,roomName)
    end
  end
end

function IRCServer:processStreamStart(update)
  local stream = Stream:find({ id = update.id })
  local sas = stream:get_streams_accounts()
  local user = stream:get_user()
  local roomName = slugify(user.username) .. '-' ..stream.slug
  local topic = 'Status: live'

  for _,sa in pairs(sas) do
    local account = sa:get_account()
    account.network = networks[account.network]
    local accountUsername = slugify(account.network.name)..'-'..account.slug
    if not self.users[accountUsername] then
      self.users[accountUsername] = {
        user = {
          nick = accountUsername,
          username = accountUsername,
          realname = accountUsername
        },
        account_id = account.id,
        network = account.network,
      }
    end
    self.rooms[roomName].users[accountUsername] = true
    for u,user in pairs(self.rooms[roomName].users) do
      if self.users[u].socket then
        self:sendRoomJoin(u,accountUsername,roomName)
      end
    end
    local http_url = sa:get('http_url')
    if http_url then
      topic = topic .. ' ' .. http_url
    end
  end
  self.rooms[roomName].topic = topic
  self:sendRoomTopic(roomName)
end

function IRCServer:processStreamUpdate(update)
  local stream = Stream:find({ id = update.id })
  local user = stream:get_user()
  local roomName = slugify(user.username) .. '-' ..stream.slug
  ngx.log(ngx.DEBUG,roomName)
  local room = self.rooms[roomName]
  if not room then
    room = {
      user_id = user.id,
      stream_id = stream.id,
      topic = 'Status: offline',
      mtime = date.diff(stream.updated_at,date.epoch()):spanseconds(),
      ctime = date.diff(stream.created_at,date.epoch()):spanseconds(),
      users = {
        ['root'] = true,
      }
    }
    local oldroomName, oldroom
    for k,v in pairs(self.rooms) do
      if v.stream_id == stream.id then
        oldroomName = k
        oldroom = v
        break
      end
    end
    if oldroom then
      for u,_ in pairs(oldroom.users) do
        -- only copy bots
        if self.users[u].network then
          room.users[u] = true
        end
        if self.users[u].socket then
          self:sendFromClient(u,'root','KICK','#'..oldroomName,u,'Room moving to #'..roomName)
        end
      end
      self.rooms[oldroomName] = nil
    end
    self.rooms[roomName] = room
  end
end

function IRCServer:processStreamEnd(update)
  local stream = Stream:find({ id = update.id })
  local sas = stream:get_streams_accounts()
  local user = stream:get_user()
  local roomName = slugify(user.username) .. '-' ..stream.slug
  for u,user in pairs(self.rooms[roomName].users) do
    if not self.users[u].user.id then
      if self.user then
        self:sendRoomPart(self.user.nick,u,roomName)
      end
      self.rooms[roomName].users[u] = nil
    end
  end

  self.rooms[roomName].topic = 'Status: offline'
  self:sendRoomTopic(roomName)
end

function IRCServer:processCommentUpdate(update)
  local account = Account:find({ id = update.account_id })
  local user = account:get_user()
  account.network = networks[account.network]
  local stream = Stream:find({ id = update.stream_id })
  local username = slugify(update.from.name)..'-'..update.network
  local roomname = slugify(user.username) .. '-' .. stream.slug

  for u,user in pairs(self.rooms[roomname].users) do
    local r = '#' .. roomname
    if self.users[u].socket then
      if update.type == 'text' then
        self:sendPrivMessage(u,username,r,update.text)
      elseif update.type == 'emote' then
        self:sendPrivMessage(u,username,r,char(1)..'ACTION ' ..update.text ..char(1))
      end
    end
  end
end

function IRCServer:processIrcJoin(msg)
  self.rooms[msg.room].users[msg.nick] = true
  for to,_ in pairs(self.rooms[msg.room].users) do
    if self.users[to].socket then
      self:sendRoomJoin(to,msg.nick,msg.room)
    end
  end
end

function IRCServer:processIrcPart(msg)
  self.rooms[msg.room].users[msg.nick] = false
  for to,_ in pairs(self.rooms[msg.room].users) do
    if self.users[to].socket then
      self:sendRoomPart(to,msg.nick,msg.room,msg.message)
    end
  end
end

function IRCServer:processIrcLogin(msg)
  if not self.users[msg.nick] then
    self.users[msg.nick] = {
      user = {
        nick = msg.nick,
        username = msg.username,
        realname = msg.realname,
        id = msg.id,
      }
    }
  end
end

function IRCServer:processIrcLogout(msg)
  for r,room in pairs(self.rooms) do
    if room.users[msg.nick] then
      for u,user in pairs(room.users) do
        if self.users[u] and self.users[u].socket then
          self:sendRoomPart(u,msg.nick,r)
        end
      end
      room.users[msg.nick] = nil
    end
  end
  self.users[msg.nick] = nil
end

function IRCServer:processIrcMessage(msg)
  if msg.target:sub(1,1) == '#' then
    local room = msg.target:sub(2)
    if self.rooms[room] then
      for u,user in pairs(self.rooms[room].users) do
        if u ~= msg.nick and self.users[u].socket then
          self:sendPrivMessage(u,msg.nick,'#'..room,msg.message)
        end
      end
    end
  else
    if self.users[msg.target] and self.users[msg.target].socket then
      self:sendPrivMessage(msg.target,msg.nick,msg.nick,msg.message)
    end
  end
end

function IRCServer:userList(room)
  local count = 0
  local ulist = ''
  for u,_ in pairs(self.rooms[room].users) do
    count = count + 1
    if u == 'root' then
      u = '@'..u
    end
    if count > 1 then
      u = ' '..u
    end
    ulist = ulist .. u
  end
  return count, ulist
end

function IRCServer:listRooms(nick,rooms)
  local ok, err = self:sendClientFromServer(nick,'321','Channel','Users','Name')
  if not ok then return false,err end
  for k,v in pairs(rooms) do
    local count, list = self:userList(k)
    local ok, err = self:sendClientFromServer(
      nick,
      '322',
      '#'..k,
      count,
      v.topic)
    if not ok then return false,err end
  end
  ok, err = self:sendClientFromServer(
    nick,
    '323',
    'End of /LIST')
  if not ok then return false,err end
  return true, nil
end

function IRCServer:clientWhois(nick,msg)
  local nicks = msg.args[1]:split(',')
  for _,n in ipairs(nicks) do
    if self.users[n] then
      local ok, err = self:sendClientFromServer(
        nick,'311',n,self.users[n].user.username,
        config.irc_hostname,'*',self.users[n].user.realname)
      if not ok then return false, err end
      local chanlist = ''
      local i = 1
      for r,room in pairs(self.rooms) do
        if room.users[n] then
          if i > 1 then chanlist = chanlist .. ' ' end
          chanlist = chanlist .. '#'..r
          i = i + 1
        end
      end
      ok, err = self:sendClientFromServer(
        nick,'319',n,chanlist)
      if not ok then return false, err end
      ok, err = self:sendClientFromServer(
        nick,'312',n,config.irc_hostname,'Unknown')
      if not ok then return false, err end
      ok, err = self:sendClientFromServer(
        nick,'318',n,'End of /WHOIS list')
      if not ok then return false, err end
    end
  end
  return true,nil
end


function IRCServer:clientWho(nick,msg)
  local target = msg.args[1]
  if not target then
    return self:sendClientFromServer(
      nick,
      '461',
      'WHO',
      'Not enough parameters')
  end
  users = nil

  if target:sub(1,1) == '#' then
    target = target:sub(2)
    if self.rooms[target] then
      users = self.rooms[target].users
    else
      return self:sendClientFromServer(
        nick,
        '403',
        '#'..target,
        'No such channel')
    end
  else
    -- just silently swallow it up
    return true, nil
  end
  for u,_ in pairs(users) do
    local ok, err = self:sendClientFromServer(
      nick,
      '352',
      '#' .. target,
      self.users[u].user.username,
      config.irc_hostname,
      config.irc_hostname,
      u,
      'H',
      '0 '..self.users[u].user.realname
    )
    if not ok then return false, err end
  end
  return self:sendClientFromServer(
    nick,
    '315',
    '#'..target,
    'End of /WHO list')
end

function IRCServer:clientMode(nick,msg)
  local target = msg.args[1]
  if not msg.args[2] then
    return self:sendClientFromServer(nick,'324',target,'+o')
  end
  return self:sendClientFromServer(nick,'482',target,'Not an op')
end

function IRCServer:clientJoinRoom(nick,msg)
  local room = msg.args[1]
  if not room then return self:sendClientFromServer(nick,'403','Channel does not exist') end
  if room:sub(1,1) == '#' then
    room = room:sub(2)
  end
  if not self.rooms[room] then
    return self:sendClientFromServer(nick,'403','Channel does not exist')
  end
  local ok, err = publish('irc:events:join', {
    nick = nick,
    room = room
  })
  if not ok then return false, err end

  return true,nil
end

function IRCServer:clientPartRoom(nick,msg)
  local rooms = msg.args[1]:split(',')
  for i,room in ipairs(rooms) do
    if room:sub(1,1) == '#' then
      room = room:sub(2)
    end
    publish('irc:events:part', {
      nick = nick,
      room = room,
      message = msg.args[2],
    })
  end
  return true,nil
end

function IRCServer:clientMessage(nick,msg)
  local target = msg.args[1]
  local room = false
  if target:sub(1,1) == '#' then
    target = target:sub(2)
    room = true
    if not self.rooms[target] then
      return self:sendClientFromServer(nick,'403','Channel does not exist')
    end
  else
    if not self.users[target] then
      return self:sendClientFromServer(nick,'401','No such nick')
    end
  end
  publish('irc:events:message',{
    nick = nick,
    target = msg.args[1],
    message = msg.args[2],
  })
  if room then
    self:relayMessage(nick,target,msg.args[2])
    self:checkBotCommand(nick,target,msg.args[2])
  end
  return true,nil
end

function IRCServer:checkBotCommand(nick,room,message)
  if(message:sub(1,1) == '!') then
    local parts = message:sub(2):split(' ')
    local botCmd = self.botCommands[parts[1]]
    if not botCmd then
      botPublish(nick,room,'Unknown command !'..parts[1])
      botPublish(nick,room,'Try !help')
      return
    end
    botCmd.func(self,nick,room,unpack(parts,2))
  end
end

function IRCServer:botCommandSummon(nick,room,stream_nick,account_slug)
  local message = ''
  local user = User:find({username = nick})
  if not stream_nick then
    botPublish(nick,room,'Parameters are <stream-bot> <account-name>')
    botPublish(nick,room,'try !help summon')
    return
  end
  if not self.users[stream_nick] or not self.users[stream_nick].account_id then
    botPublish(nick,room,'Not an active bot: ' ..stream_nick)
    return
  end
  if not account_slug or account_slug:len() == 0 then
    local accounts = Account:select(
      'where network = ? and user_id = ? and id <> ?',
      self.users[stream_nick].network.name,
      self.users[nick].user.id,
      self.users[stream_nick].account_id)
    local message = 'Available accounts:'
    for i,account in ipairs(accounts) do
      message = message .. ' ' .. account.slug
    end
    botPublish(nick,room,message)
    return
  end

  local account = Account:find({network = self.users[stream_nick].network.name, slug = account_slug })
  if not account then
    botPublish(nick,room,'Account not found')
    return
  end

  if not account:check_user(user) then
    botPublish(nick,room,'You don\'t own that account')
  end

  publish('stream:writer',{
    worker = ngx.worker.pid(),
    account_id = account.id,
    stream_id = self.rooms[room].stream_id,
    cur_stream_account_id = self.users[stream_nick].account_id,
  })
end

function IRCServer:botCommandHelp(nick,room,cmd)
  local message = ''
  if not cmd or cmd:len() == 0 then
    message = 'Available commands:'
    for command,_ in pairs(self.botCommands) do
      message = message .. ' !' .. command
    end
    botPublish(nick,room,message)
    botPublish(nick,room,'Type !help <command> for more info')
    return
  end
  if cmd:sub(1,1) == '!' then
    cmd = cmd:sub(2)
  end
  local botCmd = self.botCommands[cmd]
  if not botCmd then
    botPublish(nick,room,'Unknown command !'..cmd)
    botPublish(nick,room,'Try !help')
    return
  end
  for i,v in ipairs(botCmd.help) do
    botPublish(nick,room,v)
  end
end

function IRCServer:relayMessage(nick,room,message)
  if(message:sub(1,1) == '@') then
    message = message:sub(2)
  end
  local i = message:find(' ')
  if not i then return end
  local username = message:sub(1,i-1)
  username = username:gsub('[^a-z]$','')
  local msg = message:sub(i+1)
  if msg:len() == 0 then return end

  if self.users[username] and self.users[username].account_id and self.rooms[room].users[username] == true then
    local account = Account:find({id = self.users[username].account_id})
    if account:check_user(self.users[nick].user) then
      if self.users[username].network.write_comments then
        local stream_id = self.rooms[room].stream_id
        local account_id = self.users[username].account_id
        publish('comment:out', {
          stream_id = stream_id,
          account_id = account_id,
          text = msg,
        })
      else
        publish('irc:events:message',{
          nick = username,
          target = '#' .. room,
          message = nick .. ': not supported',
        })
      end
    else
      publish('irc:events:message',{
        nick = username,
        target = '#' .. room,
        message = nick .. ': not authorized',
      })
    end
  end
end

function IRCServer:clientPing(nick,msg)
  return self:sendFromServer(nick,'PONG',msg.args[1])
end

function IRCServer:sendRoomPart(to,from,room,message)
  local ok, err = self:sendFromClient(to,from,'PART','#'..room,message)
  if not ok then return false, err end
  return true,nil
end

function IRCServer:sendPrivMessage(to,msgFrom,msgTarget,message)
  return self:sendFromClient(to,msgFrom,'PRIVMSG',msgTarget,message)
end


function IRCServer:sendRoomJoin(to,from,room)
  local ok, err = self:sendFromClient(to,from,'JOIN','#'..room)
  if not ok then return false, err end

  if to ~= from then return true,nil end

  local code, topic
  if self.rooms[room].topic then
    code = '332'
    topic = self.rooms[room].topic
  else
    code = '331'
    topic = 'Topic not set'
  end

  ok, err = self:sendClientFromServer(from,code,'#'..room,topic)
  if not ok then return false,err end

  ok, err = self:sendNames(from,room)
  if not ok then return false, err end

  return true
end

function IRCServer:sendNames(nick,room)
  local count, userlist = self:userList(room)
  local ok, err = self:sendClientFromServer(
    nick,
    '353',
    '@',
    '#'..room,
    userlist)
  if not ok then return false, err end
  return self:sendClientFromServer(
    nick,
    '366',
    '#' .. room,
    'End of /NAMES list')
end

function IRCServer:clientList(nick,msg)
  if msg.args[1] then
    local room = msg.args[1]
    if room:sub(1,1) == '#' then
      room = room:sub(2)
    end
    return self:listRooms(nick,{ [room] = self.rooms[room] })
  end
  return self:listRooms(nick,self.rooms)
end


function IRCServer:checkNick(nick)
  if self.users[nick] then
    return true
  end
  return false
end

function IRCServer:clientQuit(nick,msg)
  self:endClient({ nick = nick })
  return true,nil
end

function IRCServer:endClient(user)
  if self.socket then
    self.socket = nil
  end
  self.users[user.nick] = nil
  publish('irc:events:logout',{
    nick = user.nick,
  })
end

function IRCServer:sendRoomTopic(roomName)
  for u,_ in pairs(self.rooms[roomName].users) do
    if self.users[u] and self.users[u].socket then
      self:sendFromClient(u,'root','TOPIC','#'..roomName,self.rooms[roomName].topic)
    end
  end
end

function IRCServer:processClientMessage(nick,msg)
  if not msg or not msg.command then
    return false, 'command not given'
  end
  local func = self.clientFunctions[msg.command:upper()]
  if not func then
    return true,nil
  end
  return func(self,nick,msg)
end

function IRCServer:sendFromClient(to,from,...)
  local full_from = from .. '!' .. from .. '@' .. config.irc_hostname
  local msg = irc.format_line(':'..full_from,...)
  ngx.log(ngx.DEBUG,msg)
  local bytes, err = self.users[to].socket:send(msg .. '\r\n')
  if not bytes then
    return false, err
  end
  return true, nil
end

function IRCServer:sendClientFromServer(nick,...)
  local args = {...}
  insert(args,2,nick)
  return self:sendFromServer(nick,unpack(args))
end

function IRCServer:sendFromServer(nick,...)
  local msg = irc.format_line(':' .. config.irc_hostname,...)
  if self.users[nick].socket then
    ngx.log(ngx.DEBUG,msg)
    local bytes, err = self.users[nick].socket:send(msg .. '\r\n')
    if not bytes then
      return false, err
    end
    return true, nil
  end
  return false, 'socket not available'
end

function IRCServer:isReady()
  return self.ready
end

function IRCServer.startClient(sock,server)
  local logging_in = true
  local user
  local nickname
  local username
  local realname
  local password
  local pass_incoming = false
  local ready_to_attempt = true
  local send_buffer = {}
  local function drain_buffer()
    while(#send_buffer > 0) do
      local v = remove(send_buffer, 1)
      if nickname then
        v = v:gsub('{nick}',nickname)
      end
      if username then
        v = v:gsub('{user}',username)
      end
      if user then
        v = v:gsub('{account}',user.username)
      end
      v = v:gsub('{hostname}',config.irc_hostname)
      sock:send(v .. '\r\n')
    end
  end
  while logging_in do
    local data, err, partial = sock:receive('*l')
    local msg
    if data then
      msg = irc.parse_line(data)
    elseif partial then
      msg = irc.parse_line(partial)
    end
    if err then
      ngx.exit(ngx.ERROR)
    end

    if msg.command == 'PASS' then
      if not msg.args[1] then
        logging_in = false
        break
      end
      password = msg.args[1]
    end

    if msg.command == 'NICK' then
      if not msg.args[1] then
        logging_in = false
        break
      end

      local res, err = server:checkNick(msg.args[1])

      if res == true then
        sock:send(':' .. config.irc_hostname .. ' 443 * '..msg.args[1]..' :Nick already in use\r\n')
        logging_in = false
        break
      end
      nickname = msg.args[1]
    end

    if msg.command == 'USER' then
      if not msg.args[1] then
        logging_in = false
        break
      end
      username = msg.args[1]
      realname = msg.args[4]
    end

    if msg.command == 'CAP' then
      if msg.args[1] == 'LS' then
        insert(send_buffer,':{hostname} CAP * LS :multi-prefix sasl')
        ready_to_attempt = false
      elseif msg.args[1] == 'REQ' then
        insert(send_buffer,':{hostname} CAP {nick} ACK :'..msg.args[2])
        ready_to_attempt = false
      elseif msg.args[1] == 'END' then
        ready_to_attempt = true
      end
    end
    if msg.command == 'AUTHENTICATE' then
      if pass_incoming then
        local creds = ngx.decode_base64(msg.args[1]):split(char(0))
        user = User:login(creds[2],creds[3])
        if user then
          if user.username ~= nickname then
            insert(send_buffer,':{hostname} 902 {nick} :You must use a nick assigned to you')
            user = nil
          else
            insert(send_buffer,':{hostname} 900 {nick} {nick}!{user}@{hostname} {account} :You are now logged in as {user}')
            insert(send_buffer,':{hostname} 903 {nick} :SASL authenticate successful')
          end
        else
          insert(send_buffer,':{hostname} 904 {nick} :SASL authentication failed')
        end
      else
        if msg.args[1] == '*' then
          insert(send_buffer,':{hostname} 906 {nick} :SASL aborted')
        elseif msg.args[1] ~= 'PLAIN' then
          insert(send_buffer,':{hostname} 908 {nick} PLAIN :Available SASL methods')
        else
          insert(send_buffer,':{hostname} AUTHENTICATE +')
          pass_incoming = true
        end
      end
    end
    if nickname and username then
      drain_buffer()
      if ready_to_attempt then
        logging_in = false
      end
    end

    if err == 'closed' then
      logging_in = false
    end
  end

  if not user then
    if password and nickname then
      user = User:login(nickname,password)
    end
  end

  if user then
    insert(send_buffer,':{hostname} 001 {nick} :Welcome {nick}!{user}@{hostname}')
    insert(send_buffer,':{hostname} 002 {nick} :Your host is {hostname}, running version 1.0.0')
    insert(send_buffer,':{hostname} 003 {nick} :This server was created ' .. date(start_time):fmt('%a %b %d %Y at %H:%M:%S UTC'))
    insert(send_buffer,':{hostname} 004 {nick} :{hostname} multistreamer 1.0.0 o o')
    insert(send_buffer,':{hostname} 375 {nick} :- {hostname} Message of the day -')
    insert(send_buffer,':{hostname} 372 {nick} :- MOTD goes here')
    insert(send_buffer,':{hostname} 376 {nick} :End of MOTD')

    drain_buffer()
    local u = {
      id = user.id,
      nick = nickname,
      username = username,
      realname = realname,
    }
    return true, u
  end
  return false, 'login failed'
end

return IRCServer
