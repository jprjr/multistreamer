-- luacheck: globals ngx uuid start_time networks
local ngx = ngx
local uuid = uuid
local start_time = start_time
local networks = networks

local IRCState = require'multistreamer.irc.state'
local irc = require'multistreamer.irc'
local config = require'multistreamer.config'
local date = require'date'
local from_json = require('lapis.util').from_json
local User = require'models.user'
local Stream = require'models.stream'
local Account = require'models.account'
local SharedAccount = require'models.shared_account'
local string = require'multistreamer.string'

local insert = table.insert
local remove = table.remove
local concat = table.concat
local char = string.char
local len = string.len
local sub = string.sub
local find = string.find
local lower = string.lower
local gsub = string.gsub
local split = string.split
local escape_markdown = string.escape_markdown
local pairs = pairs
local ipairs = ipairs
local ngx_log = ngx.log
local ngx_exit = ngx.exit
local ngx_error = ngx.ERROR
local ngx_err = ngx.ERR
local coro_status = coroutine.status
local unpack = unpack or table.unpack -- luacheck: compat
local floor = math.floor
local now = ngx.now

local redis = require'multistreamer.redis'
local publish = redis.publish

local IRCServer = {}
IRCServer.__index = IRCServer

function IRCServer.new(socket,user,stateServer)
  local server = {
    uuid = uuid(),
    rooms = stateServer:getRooms(),
    users = stateServer:getUsers(),
    user = user, -- user = user object
    socket = socket,
    sent_quit = false,
  }

  server.user.rooms = {}
  server.users[server.user.username] = {
    id = user.id,
    connections = {}
  }
  server.users[server.user.username].connections[server.uuid] = {
    rooms = {}
  }

  setmetatable(server,IRCServer)
  return server
end

function IRCServer:run()
  local ok, red = IRCState.createSubscriptions()
  if not ok then
    ngx_exit(ngx_error)
  end

  local red_func = ngx.thread.spawn(function()
    while true do
      local res, err = red:read_reply()
      if err and err ~= 'timeout' then
        ngx_log(ngx_err,'[IRC] Redis disconnected!')
        return false
      end
      if res then
        local func = IRCState.redisFunctions[res[2]]
        if func then
          local _, results = func(self,from_json(res[3]))
          for _,result in ipairs(results) do
            if IRCServer.stateFunctions[result['type']] then
              IRCServer.stateFunctions[result['type']](self,result)
            end
          end
        end
      end
    end
  end)
  local irc_func = ngx.thread.spawn(function()
    while true do
      if not self.socket then return end
      local data, err, partial = self.socket:receive('*l')
      local msg
      if data then
        msg = irc.parse_line(data)
      elseif partial then
        msg = irc.parse_line(partial)
      end
      if err and err == 'closed' then
        return
      end
      if not err or err ~= 'timeout' then
        local irc_ok, irc_err = self:processClientMessage(msg)
        if not irc_ok then
          ngx_log(ngx_err,'[IRC] ' .. irc_err)
          return
        end
      end
    end
  end)

  publish('irc:events:login', {
    nick = self.user.username,
    user_id = self.user.id,
    uuid = self.uuid,
    irc = true,
  })

  -- find and force-join user to rooms
  if config.irc_force_join then
    for roomName,room in pairs(self.rooms) do
      if room.live then
        local stream_user = Stream:find({ id = room.stream_id }):get_user()
        if stream_user.id == self.user.id then
          publish('irc:events:join', {
            nick = self.user.username,
            user_id = self.user.id,
            room = roomName,
            uuid = self.uuid,
          })
        end
      end
    end
  end

  ngx.thread.wait(irc_func,red_func)
  if coro_status(red_func) == 'dead' then
    ngx.thread.kill(irc_func)
  else
    ngx.thread.kill(red_func)
  end
  self:endClient()
end

function IRCServer:processClientMessage(msg)
  if not msg or not msg.command then
    return false, 'command not given'
  end
  local func = IRCServer.clientFunctions[msg.command:upper()]
  if not func then
    return true,nil
  end
  return func(self,msg)
end


function IRCServer.stateUserLogin()
  -- right now, do nothing
  -- in the future, implement code
  -- for buddy lists
  -- state is handled by IRCState module
  return true
end

function IRCServer.stateUserLogout()
  -- userLogout will be preceeded with
  -- any necessary roomParts
  -- so no action needed, unless I
  -- get into implementing buddy lists
  -- state is handled by IRCState module
  return true
end

function IRCServer.stateRoomCreate()
  -- do nothing
  return true
end

function IRCServer:stateRoomDelete(data)
  if self.user.rooms[data.roomName] then
    self.user.rooms[data.roomName] = nil
    return self:sendRoomPart(self.user.username,data.roomName, 'Room destroyed')
  end
  return true
end

function IRCServer:stateRoomUpdate(data)
  if self.user.rooms[data.roomName] then
    return self:sendRoomTopic(data.roomName)
  end

  -- if user isn't already in room and force_join is on, bring them in

  if data.live == true and config.irc_force_join then
    local stream = Stream:find({ id = self.rooms[data.roomName].stream_id })
    if stream.user_id == self.user.id then
      publish('irc:events:join', {
        nick = self.user.username,
        user_id = self.user.id,
        room = data.roomName,
        uuid = self.uuid
      })
    end
  end
  return true
end

function IRCServer:stateRoomMove(data)
  if self.user.rooms[data.oldRoomName] then
    self.user.rooms[data.oldRoomName] = nil
    local ok, err = self:sendRoomPart(self.user.username,data.oldRoomName, 'Room moving to ' .. data.roomName)
    if not ok then
      return false, err
    end
    self.user.rooms[data.roomName] = true
    return self:sendRoomJoin(self.user.username,data.roomName)
  end
  return true
end

function IRCServer:stateRoomJoin(data)
  -- only display joins for other users
  if self.user.rooms[data.roomName] and data.username ~= self.user.username then
    return self:sendRoomJoin(data.username,data.roomName)
  end
  -- perform a join for ourselves
  if not self.user.rooms[data.roomName] and data.username == self.user.username then
    return self:sendRoomJoin(data.username,data.roomName)
  end
  return true
end

function IRCServer:stateRoomConnJoin(data)
  if self.uuid == data.connid then
    self.user.rooms[data.roomName] = true
    return self:sendRoomJoin(self.user.username,data.roomName)
  end
  return true
end

function IRCServer:stateRoomPart(data)
  -- only display parts for other users
  if self.user.rooms[data.roomName] and data.username ~= self.user.username then
    return self:sendRoomPart(data.username,data.roomName)
  end
  return true
end

function IRCServer:stateRoomConnPart(data)
  if self.user.rooms[data.roomName] and self.uuid == data.connid then
    self.user.rooms[data.roomName] = nil
    return self:sendRoomPart(self.user.username,data.roomName)
  end
  return true
end

function IRCServer:stateWriterAvailable(data)
  if self.user.rooms[data.roomName] then
    return self:sendRoomJoin(data.username,data.roomName)
  end
  return true
end

function IRCServer.stateViewcountUpdate()
  return true
end

function IRCServer:stateIrcMessage(data)
  return self:sendPrivMessage(data.from,data.to,data.text)
end

function IRCServer:stateIrcInvite(data)
  return self:sendFromClient(data.from,'INVITE',data.to,':'..data.room)
end

function IRCServer:userList(room)
  local ulist = '@root'
  local count = 1
  for u,_ in pairs(self.rooms[room].users) do
    count = count + 1
    ulist = ulist .. ' ' .. u
  end
  for u,_ in pairs(self.rooms[room].bots) do
    count = count + 1
    ulist = ulist .. ' ' .. u
  end
  return count, ulist
end

function IRCServer:listRooms(rooms)
  local ok, err = self:sendClientFromServer('321','Channel','Users','Name')
  if not ok then return false,err end
  for k,v in pairs(rooms) do
    local stream = Stream:find({id = v.stream_id})
    local chat_level = stream:check_chat(self.user)
    if chat_level > 0 then
      local count, _ = self:userList(k)
      local c_ok, c_err = self:sendClientFromServer(
        '322',
        '#'..k,
        count,
        v.topic)
      if not c_ok then return false,c_err end
    end
  end
  return self:sendClientFromServer('323','End of /LIST')
end

function IRCServer:clientAway(msg)
  if #msg.args > 0 then
    return self:sendClientFromServer('306','You have been marked as being away')
  else
    return self:sendClientFromServer('305','You are no longer marked as being away')
  end
end

function IRCServer:clientIson(msg)
  local resp = ''
  local i = 1
  for _,u in pairs(msg.args) do
    if self.users[u] then
      if i > 1 then
        u = ' ' .. u
      end
      resp = resp .. u
    end
  end
  return self:sendClientFromServer('303',resp)
end

function IRCServer:clientUserhost(msg)
  local resp = ''
  local i = 1
  for _,u in pairs(msg.args) do
    if self.users[u] then
      if i > 1 then
        resp = resp .. ' '
      end
      resp = resp .. u .. '=' .. u .. '@' .. config.irc_hostname
      i = i + 1
    end
  end
  return self:sendClientFromServer('302', resp)
end

function IRCServer:clientWhois(msg)
  local nicks = split(msg.args[1],',')
  for _,n in ipairs(nicks) do
    if self.users[n] then
      local ok, err = self:sendClientFromServer(
        '311',n,n,
        config.irc_hostname,'*',n)
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
      ok, err = self:sendClientFromServer('319',n,chanlist)
      if not ok then return false, err end
      ok, err = self:sendClientFromServer('312',n,config.irc_hostname,'Unknown')
      if not ok then return false, err end
      ok, err = self:sendClientFromServer('318',n,'End of /WHOIS list')
      if not ok then return false, err end
    end
  end
  return true,nil
end


function IRCServer:clientWho(msg)
  local target = msg.args[1]
  if not target then
    return self:sendClientFromServer(
      '461',
      'WHO',
      'Not enough parameters')
  end
  local users

  if sub(target,1,1) == '#' then
    target = sub(target,2)
    if self.rooms[target] then
      users = self.rooms[target].users
    else
      return self:sendClientFromServer(
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
      '352',
      '#' .. target,
      u,
      config.irc_hostname,
      config.irc_hostname,
      u,
      'H',
      '0 '..u
    )
    if not ok then return false, err end
  end
  return self:sendClientFromServer(
    '315',
    '#'..target,
    'End of /WHO list')
end

function IRCServer:clientMode(msg)
  local target = msg.args[1]
  if not msg.args[2] then
    return self:sendClientFromServer('324',target,'+o')
  end
  return self:sendClientFromServer('482',target,'Not an op')
end

function IRCServer:clientInvite(msg)
  if not msg.args[2] then
    return self:sendClientFromServer('461','INVITE','Not enough parameters')
  end
  local user = msg.args[1]
  local room = sub(msg.args[2],2)

  if not self.users[user] or not self.rooms[room] then
    return self:sendClientFromServer('401',user,'No such nick/channel')
  end

  if self.rooms[room].users[user] then
    return self:sendClientFromServer('443',user,'#'..room,'is already on channel')
  end

  publish('irc:events:invite',{
    from = self.user.username,
    to = user,
    room = room,
  })

  return self:sendClientFromServer('341',user,'#'..room)
end

function IRCServer:clientOper()
  return self:sendClientFromServer('464','Password incorrect')
end

function IRCServer:clientNotOp()
  return self:sendClientFromServer('481','Permission Denied- You\'re not an IRC operator')
end

function IRCServer:clientNotChanOp(msg)
  return self:sendClientFromServer('482',msg.args[1],'You\'re not channel operator')
end

function IRCServer:clientSummon()
  return self:sendClientFromServer('445','SUMMON has been disabled')
end

function IRCServer:clientUsers()
  return self:sendClientFromServer('446','USERS has been disabled')
end

function IRCServer:clientUnknown(msg)
  return self:sendClientFromServer('421',msg.command:upper(),'Unknown command')
end

function IRCServer:clientJoinRoom(msg)
  if not msg.args[1] then return self:sendClientFromServer('403','Channel does not exist') end

  local rooms = split(msg.args[1],',')

  for _,room in ipairs(rooms) do

    if sub(room,1,1) == '#' then
      room = sub(room,2)
    end
    if not self.rooms[room] then
      return self:sendClientFromServer('403','Channel does not exist')
    end
    local stream = Stream:find({ id = self.rooms[room].stream_id })
    local chat_level = stream:check_chat(self.user)
    if chat_level < 1 then
      return self:sendClientFromServer('403','Channel does not exist')
    end

    publish('irc:events:join', {
      nick = self.user.username,
      user_id = self.user.id,
      room = room,
      uuid = self.uuid
    })
  end

  return true,nil
end

function IRCServer:clientPartRoom(msg)
  local rooms = split(msg.args[1],',')
  for _,room in ipairs(rooms) do
    if sub(room,1,1) == '#' then
      room = sub(room,2)
    end

    publish('irc:events:part', {
      nick = self.user.username,
      room = room,
      message = msg.args[2],
      uuid = self.uuid,
    })
  end
  return true,nil
end

function IRCServer:clientMessage(msg)
  local target = msg.args[1]
  local room = false
  if sub(target,1,1) == '#' then
    target = sub(target,2)
    room = true
    if not self.rooms[target] then
      return self:sendClientFromServer('403','Channel does not exist')
    end
  else
    if not self.users[target] then
      return self:sendClientFromServer('401','No such nick')
    end
  end
  if room then
    self:checkBotCommand(target,msg.args[2])
  end

  self:relayMessage(room,target,msg.args[2])
  return true,nil
end

function IRCServer:checkBotCommand(room,message)
  if(sub(message,1,1) == '!') then
    local parts = split(sub(message,2),' ')
    local botCmd = IRCServer.botCommands[parts[1]]
    if not botCmd then
      self:botPublish(room,'Unknown command !'..parts[1])
      self:botPublish(room,'Try !help')
      return
    end
    botCmd.func(self,room,unpack(parts,2))
  end
end

function IRCServer:botCommandViewcount(room,stream_nick)
  if not self.rooms[room].live then
    self:botPublish(room,'Not streaming right now')
    return true
  end
  if not stream_nick then
    for u,bot in pairs(self.rooms[room].bots) do
      if bot.viewer_count ~= nil then
        publish('irc:events:message', {
          nick = u,
          target = '#'..room,
          message = bot.viewer_count .. ' viewers'
        })
      else
        publish('irc:events:message', {
          nick = u,
          target = '#'..room,
          message = 'unknown viewers'
        })
      end
    end
  else
    if not self.rooms[room].bots[stream_nick].account_id then
      self:botPublish(room,'Not an active bot: ' .. stream_nick)
    else
      if self.rooms[room].bots[stream_nick].viewer_count ~= nil then
        publish('irc:events:message', {
          nick = stream_nick,
          target = '#'..room,
          message = self.rooms[room].bots[stream_nick].viewer_count .. ' viewers'
        })
      else
        publish('irc:events:message', {
          nick = stream_nick,
          target = '#'..room,
          message = 'unknown viewers'
        })
      end
    end
  end
end

function IRCServer:botCommandChatWriter(room,target,account_slug)
  if not target then
    self:botPublish(room,'Missing parameters')
    self:botPublish(room,'try !help chat')
    return
  end

  target = target:lower()
  local network
  local tar_account_id

  if networks[target] then
    network = target
  elseif self.rooms[room].bots[target] then
    local account = Account:find({ id = self.rooms[room].bots[target].account_id })
    network = account.network
    tar_account_id = self.rooms[room].bots[target].tar_account_id
  else
    self:botPublish(room,'Not a network or bot: ' .. target)
    return
  end

  -- user checking what accounts are available
  if not account_slug or len(account_slug) == 0 then
    local accounts = Account:select(
        'where network = ? and user_id = ?',
        network,
        self.user.id
    )
    local sas = SharedAccount:select(
      'where user_id = ?',
      self.user.id)
    local message = 'Available accounts:'
    for _,account in ipairs(accounts) do
      message = message .. ' ' .. account.slug
    end
    for _,sa in ipairs(sas) do
      local account = sa:get_account()
      if account.network == network then
        message = message .. ' ' .. account.slug
      end
    end
    self:botPublish(room,message)
    return
  end

  if not tar_account_id then
    -- see if there's only 1 account for the network
    local l_network = {}
    local c = 0
    local stream = Stream:find({ id = self.rooms[room].stream_id })
    for _,sa in pairs(stream:get_streams_accounts()) do
      local acc = sa:get_account()
      if acc.network == network then
        insert(l_network,acc)
        c = c + 1
      end
    end
    if c == 1 then
      tar_account_id = l_network[1].id
    end
  end

  if not tar_account_id then
    self:botPublish(room,'Please specify a bot instead of a network')
    return
  end
  local tar_account = Account:find({id = tar_account_id})

  if self.rooms[room].bots[network .. '-' .. account_slug] or
     self.rooms[room].bots[network .. '-' .. account_slug .. '-' .. tar_account.slug] then
    self:botPublish(room,'Relay bot already exists')
    return
  end

  local account = Account:find({network = network, slug = account_slug })
  if not account then
    self:botPublish(room,'Account not found')
    return
  end

  if not account:check_user(self.user) then
    self:botPublish(room,'You can\'t use that account')
    return
  end

  publish('stream:writer', {
    worker = ngx.worker.pid(),
    account_id = account.id,
    user_id = self.user.id,
    stream_id = self.rooms[room].stream_id,
    cur_stream_account_id = tar_account_id,
  })

end

function IRCServer:botCommandSummon(room,stream_nick)
  if not stream_nick then
    self:botPublish(room,'Missing parameters')
    self:botPublish(room,'try !help summon')
    return
  end

  if not self.users[stream_nick] then
    self:botPublish(room,'No such nick')
    return
  end

  if self.rooms[room].users[stream_nick] then
    self:botPublish(room,'That user is already here')
    return
  end

  if not self.users[stream_nick].irc then
    self:botPublish(room,'User not connected with IRC')
    return
  end

  publish('irc:events:summon', {
    nick = stream_nick,
    room = room,
  })

  return
end

function IRCServer:botCommandHelp(room,cmd)
  if not cmd or len(cmd) == 0 then
    local message = 'Available commands:'
    for command,_ in pairs(IRCServer.botCommands) do
      message = message .. ' !' .. command
    end
    self:botPublish(room,message)
    self:botPublish(room,'Type !help <command> for more info')
    return
  end
  if sub(cmd,1,1) == '!' then
    cmd = sub(cmd,2)
  end
  local botCmd = IRCServer.botCommands[cmd]
  if not botCmd then
    self:botPublish(room,'Unknown command !'..cmd)
    self:botPublish(room,'Try !help')
    return
  end
  for _,v in ipairs(botCmd.help) do
    self:botPublish(room,v)
  end
end

function IRCServer:relayMessage(isroom,target,message)
  local t = 'text'

  -- check if this is a CTCP ACTION (aka emote)
  if message:byte(1) == 1 then
    local m = sub(message,2,len(message)-1)
    local p = split(m,' ')
    if p[1] == 'ACTION' then
      t = 'emote'
      message = concat(p,' ',2)
    end
  end

  local m = {
    ['type'] = t,
    account_id = 0,
    text = message,
    uuid = self.uuid,
    network = 'irc',
    timestamp = floor(now() * 1000),
    markdown = escape_markdown(message),
    from = {
        name = self.user.username,
        id = self.user.id,
    },
    relay = false
  }

  if not isroom then
    m.to = {
      id = self.users[target].id,
      name = target,
    }
    publish('comment:in',m)
    return
  end

  m.stream_id = self.rooms[target].stream_id

  if sub(message,1,1) == '!' then
    m.relay = true
  end

  if(sub(message,1,1) == '@') then
    message = sub(message,2)
  end

  local i = find(message,' ')
  if not i then
    publish('comment:in',m)
    return
  end

  local username = lower(sub(message,1,i-1))
  username = gsub(username,'[^a-z]$','')
  local msg = sub(message,i+1)
  if len(msg) == 0 then
    publish('comment:in',m)
    return
  end


  if self.rooms[target].bots[username] then
    m.relay = true
    publish('comment:in',m)

    local account = Account:find({id = self.rooms[target].bots[username].account_id})
    local stream = Stream:find({id = self.rooms[target].stream_id})

    local user_ok = account:check_user(self.user)
    local chat_level = stream:check_chat(self.user)

    if user_ok or chat_level == 2 then
      if networks[self.rooms[target].bots[username].network].write_comments then
        m.network = nil
        m.from = nil
        m.uuid = nil
        m.markdown = nil
        m.account_id = self.rooms[target].bots[username].account_id
        m.cur_stream_account_id = self.rooms[target].bots[username].tar_account_id
        m.text = msg
        publish('comment:out', m)
      else
        publish('irc:events:message',{
          nick = username,
          target = '#' .. target,
          message = self.user.username .. ': not supported',
        })
      end
    else
      publish('irc:events:message',{
        nick = username,
        target = '#' .. target,
        message = self.user.username .. ': not authorized',
      })
    end
  else
    publish('comment:in',m)
  end
end

function IRCServer:clientPing(msg)
  return self:sendFromServer('PONG',msg.args[1])
end


function IRCServer:clientList(msg)
  if msg.args[1] then
    local room = msg.args[1]
    if sub(room,1,1) == '#' then
      room = sub(room,2)
    end
    return self:listRooms({ [room] = self.rooms[room] })
  end
  return self:listRooms(self.rooms)
end

function IRCServer:clientQuit(msg)
  publish('irc:events:logout', {
    nick = self.user.username,
    uuid = self.uuid,
    message = msg.args[1] or ''
  })
  self.sent_quit = true
  self:endClient()
  return true,nil
end

function IRCServer:endClient()
  if not self.sent_quit then
    publish('irc:events:logout', {
      nick = self.user.username,
      uuid = self.uuid,
      message = 'Disconnected'
    })
    self.sent_quit = true
  end

  if self.socket and self.socket.close then
    self.socket:close()
    self.socket = nil
  end
end

function IRCServer:sendRoomTopic(roomName)
  return self:sendFromClient('root','TOPIC','#' .. roomName,self.rooms[roomName].topic)
end

function IRCServer:sendRoomJoin(from,roomName)
  local ok, err = self:sendFromClient(from,'JOIN','#'..roomName)
  if not ok then return false, err end

  if from == self.user.username then
    local code, topic
    if self.rooms[roomName].topic then
      code = '332'
      topic = self.rooms[roomName].topic
    else
      code = '331'
      topic = 'Topic not set'
    end

    ok, err = self:sendClientFromServer(code,'#'..roomName,topic)
    if not ok then return false,err end

    return self:sendNames(roomName)
  end
  return true, nil
end

function IRCServer:sendRoomPart(from,room,message)
  return self:sendFromClient(from,'PART','#' .. room,message)
end

function IRCServer:sendNames(room)
  local _, userlist = self:userList(room)
  local ok, err = self:sendClientFromServer(
    '353',
    '@',
    '#'..room,
    userlist)
  if not ok then return false, err end
  return self:sendClientFromServer(
    '366',
    '#' .. room,
    'End of /NAMES list')
end

function IRCServer:sendPrivMessage(msgFrom,msgTarget,message)
  return self:sendFromClient(msgFrom,'PRIVMSG',msgTarget,message)
end

function IRCServer:sendClientFromServer(...)
  local args = {...}
  insert(args,2,self.user.username)
  return self:sendFromServer(unpack(args))
end

function IRCServer:sendFromClient(from,...)
  local full_from = from .. '!' .. from .. '@' .. config.irc_hostname
  local msg = irc.format_line_col(':'..full_from,...)
  return self.socket:send(msg .. '\r\n')
end

function IRCServer:sendFromServer(...)
  local msg = irc.format_line_col(':' .. config.irc_hostname,...)
  return self.socket:send(msg .. '\r\n')
end

function IRCServer:botPublish(room,message)
  publish('irc:events:message', {
    bot = true,
    nick = 'root',
    target = '#'..room,
    message = self.user.username .. ': ' .. message
  })
end


function IRCServer.startClient(sock) -- {{{
  local logging_in = true
  local user
  local nickname
  local username
  local password
  local pass_incoming = false
  local ready_to_attempt = true
  local send_buffer = {}
  local function drain_buffer()
    while(#send_buffer > 0) do
      local v = remove(send_buffer, 1)
      if nickname then
        v = gsub(v,'{nick}',nickname)
      end
      if username then
        v = gsub(v,'{user}',username)
      end
      if user then
        v = gsub(v,'{account}',user.username)
      end
      v = gsub(v,'{hostname}',config.irc_hostname)
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
      ngx_exit(ngx_error)
    end

    if msg.command == 'PASS' then
      if not msg.args[1] then
        break
      end
      password = msg.args[1]
    end

    if msg.command == 'NICK' then
      if not msg.args[1] then
        break
      end

      nickname = msg.args[1]
    end

    if msg.command == 'USER' then
      if not msg.args[1] then
        break
      end
      username = msg.args[1]
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
        pass_incoming = false
        local creds = split(ngx.decode_base64(msg.args[1]),char(0))
        user = User:login(creds[2],creds[3])
        if user then
          if user.username ~= nickname then
            insert(send_buffer,':{hostname} 902 {nick} :You must use a nick assigned to you')
            user = nil
          else
            insert(send_buffer,':{hostname} 900 {nick} {nick}!{nick}@{hostname} {account} :You are now logged in as {nick}') --luacheck: ignore
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
          insert(send_buffer,'AUTHENTICATE +')
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
    local date_fmt = date(start_time):fmt('%a %b %d %Y at %H:%M:%S UTC')
    insert(send_buffer,':{hostname} 001 {nick} :Welcome {nick}!{nick}@{hostname}')
    insert(send_buffer,':{hostname} 002 {nick} :Your host is {hostname}, running version ' .. config.VERSION)
    insert(send_buffer,':{hostname} 003 {nick} :This server was created ' .. date_fmt)
    insert(send_buffer,':{hostname} 004 {nick} :{hostname} multistreamer ' .. config.VERSION .. ' o o')
    insert(send_buffer,':{hostname} 375 {nick} :- {hostname} Message of the day -')
    for _,line in pairs(split(config.irc_motd,'\r?\n')) do
      insert(send_buffer,':{hostname} 372 {nick} :- ' .. line)
    end
    insert(send_buffer,':{hostname} 376 {nick} :End of MOTD')

    drain_buffer()
    return true, user
  end
  return false, 'login failed'
end -- }}}

IRCServer.clientFunctions = {
  ['AWAY'] = IRCServer.clientAway,
  ['INVITE'] = IRCServer.clientInvite,
  ['ISON'] = IRCServer.clientIson,
  ['JOIN'] = IRCServer.clientJoinRoom,
  ['KICK'] = IRCServer.clientNotChanOp,
  ['LIST'] = IRCServer.clientList,
  ['MODE'] = IRCServer.clientMode,
  ['NOTICE'] = IRCServer.clientMessage,
  ['OPER'] = IRCServer.clientOper,
  ['OPERWALL'] = IRCServer.clientUnknown,
  ['PART'] = IRCServer.clientPartRoom,
  ['PING'] = IRCServer.clientPing,
  ['PRIVMSG'] = IRCServer.clientMessage,
  ['QUIT'] = IRCServer.clientQuit,
  ['REHASH'] = IRCServer.clientNotOp,
  ['RESTART'] = IRCServer.clientNotOp,
  ['SUMMON'] = IRCServer.clientSummon,
  ['TOPIC'] = IRCServer.clientNotChanOp,
  ['USERHOST'] = IRCServer.clientUserhost,
  ['USERS'] = IRCServer.clientUsers,
  ['WHO'] = IRCServer.clientWho,
  ['WHOIS'] = IRCServer.clientWhois,
}

IRCServer.stateFunctions = {
  ['userLogin'] = IRCServer.stateUserLogin,
  ['userLogout'] = IRCServer.stateUserLogout,
  ['roomCreate'] = IRCServer.stateRoomCreate,
  ['roomPart'] = IRCServer.stateRoomPart,
  ['roomJoin'] = IRCServer.stateRoomJoin,
  ['roomConnJoin'] = IRCServer.stateRoomConnJoin,
  ['roomConnPart'] = IRCServer.stateRoomConnPart,
  ['roomUpdate'] = IRCServer.stateRoomUpdate,
  ['roomDelete'] = IRCServer.stateRoomDelete,
  ['roomMove'] = IRCServer.stateRoomMove,
  ['writerAvailable'] = IRCServer.stateWriterAvailable,
  ['ircInvite'] = IRCServer.stateIrcInvite,
  ['ircMessage'] = IRCServer.stateIrcMessage,
}

IRCServer.botCommands = {
  ['help'] = {
    func = IRCServer.botCommandHelp,
    help = {'Usage: !help <command> '},
  },
  ['chat'] = {
    func = IRCServer.botCommandChatWriter,
    help = {
      '!chat -- create a bot for relaying your chat',
      'Usage:',
      '!chat <network> -- list accounts for bot-creation',
      '!chat <network> <your account> -- create a bot to post comments',
      '!chat <existing bot> <your account> -- create a bot to post comments',
    },
  },
  ['summon'] = {
    func = IRCServer.botCommandSummon,
    help = {
      '!summon - summon a usert',
      'Usage:',
      '!summon <user> -- bring a user into this room',
    },
  },
  ['viewcount'] = {
    func = IRCServer.botCommandViewcount,
    help = {
      'Usage:',
      '!viewcount -- get the current viewer count',
      '!viewcount <room bot> -- get the viewer count for a single stream',
    },
  },
}

return IRCServer
