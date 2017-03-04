local irc = require'multistreamer.irc'
local config = require'multistreamer.config'
local date = require'date'
local slugify = require('lapis.util').slugify
local to_json = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local User = require'models.user'
local Stream = require'models.stream'
local Account = require'models.account'
local SharedAccount = require'models.shared_account'
local SharedStream = require'models.shared_stream'
local string = require'multistreamer.string'

local insert = table.insert
local remove = table.remove
local concat = table.concat
local char = string.char
local find = string.find
local len = string.len
local sub = string.sub
local pairs = pairs
local ipairs = ipairs
local ngx_log = ngx.log
local ngx_exit = ngx.exit
local ngx_error = ngx.ERROR
local ngx_err = ngx.ERR
local ngx_debug = ngx.DEBUG
local coro_status = coroutine.status
local unpack = unpack
if not unpack then
  unpack = table.unpack
end
local networks = networks

local redis = require'multistreamer.redis'
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
  local server = {
    ready = false,
    uuid = uuid(),
  }
  if parentServer then
    curState = parentServer:getState()
    server.socket = socket
    server.user = user
    server.rooms = curState.rooms
    server.users = curState.users
    server.users[user.nick] = {}
    server.users[user.nick].user = user
    server.users[user.nick].socket = socket
    server.users[user.nick].conns = 0

    for _,r in pairs(server.rooms) do
      r.user = User:find({id = r.user_id})
      r.stream = Stream:find({id = r.stream_id})
    end

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
    ['AWAY'] = IRCServer.clientUnknown,
    ['INVITE'] = IRCServer.clientInvite,
    ['ISON'] = IRCServer.clientIson,
    ['JOIN'] = IRCServer.clientJoinRoom,
    ['KICK'] = IRCServer.clientKick,
    ['LIST'] = IRCServer.clientList,
    ['MODE'] = IRCServer.clientMode,
    ['NOTICE'] = IRCServer.clientMessage,
    ['OPER'] = IRCServer.clientOper,
    ['OPERWALL'] = IRCServer.clientUnknown,
    ['PART'] = IRCServer.clientPartRoom,
    ['PING'] = IRCServer.clientPing,
    ['PRIVMSG'] = IRCServer.clientMessage,
    ['QUIT'] = IRCServer.clientQuit,
    ['REHASH'] = IRCServer.clientUnknown,
    ['RESTART'] = IRCServer.clientUnknown,
    ['SUMMON'] = IRCServer.clientUnknown,
    ['TOPIC'] = IRCServer.clientTopic,
    ['USERHOST'] = IRCServer.clientUnknown,
    ['USERS'] = IRCServer.clientUsers,
    ['WHO'] = IRCServer.clientWho,
    ['WHOIS'] = IRCServer.clientWhois,
  }
  server.redisFunctions = {
    [endpoint('stream:start')] = IRCServer.processStreamStart,
    [endpoint('stream:end')] = IRCServer.processStreamEnd,
    [endpoint('stream:update')] = IRCServer.processStreamUpdate,
    [endpoint('stream:writerresult')] = IRCServer.processWriterResult,
    [endpoint('stream:viewcountresult')] = IRCServer.processViewCountResult,
    [endpoint('comment:in')] = IRCServer.processCommentUpdate,
    [endpoint('irc:events:login')] = IRCServer.processIrcLogin,
    [endpoint('irc:events:logout')] = IRCServer.processIrcLogout,
    [endpoint('irc:events:join')] = IRCServer.processIrcJoin,
    [endpoint('irc:events:part')] = IRCServer.processIrcPart,
    [endpoint('irc:events:message')] = IRCServer.processIrcMessage,
    [endpoint('irc:events:invite')] = IRCServer.processIrcInvite,
  }
  server.botCommands = {
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
  setmetatable(server,IRCServer)
  return server
end

function IRCServer:run()
  local running = true

  local ok, red = subscribe('irc:events:login')
  if not ok then
    ngx_exit(ngx_error)
  end
  subscribe('irc:events:logout',red)
  subscribe('irc:events:join',red)
  subscribe('irc:events:part',red)
  subscribe('irc:events:message',red)
  subscribe('irc:events:invite',red)
  subscribe('stream:start',red)
  subscribe('stream:end',red)
  subscribe('stream:update',red)
  subscribe('stream:viewcountresult',red)
  subscribe('comment:in',red)
  subscribe('stream:writerresult',red)

  self.ready = true

  local red_func = ngx.thread.spawn(function()
    while true do
      local res, err = red:read_reply()
      if err and err ~= 'timeout' then
        ngx_log(ngx_err,'[IRC] Redis disconnected!')
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
          ngx_log(ngx_debug,data)
          msg = irc.parse_line(data)
        elseif partial then
          msg = irc.parse_line(partial)
        end
        if err and err == 'closed' then
          return
        end
        if not err or err ~= 'timeout' then
          local ok, err = self:processClientMessage(self.user.nick,msg)
          if not ok then
            ngx_log(ngx_err,'[IRC] ' .. err)
            return
          end
        end
      end
    end)

    -- find and force-join user to rooms
    if config.irc_force_join then
      local u = User:find({ id = self.user.id })
      for _,stream in ipairs(u:get_streams()) do
        local roomName = slugify(u.username) .. '-' .. stream.slug
        if self.rooms[roomName] and self.rooms[roomName].live then
          local ok, err = publish('irc:events:join', {
            nick = self.user.nick,
            room = roomName,
          })
        end
      end
    end

    local ok, irc_res, red_res = ngx.thread.wait(irc_func,red_func)
    if coro_status(red_func) == 'dead' then
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
          live = false,
          mtime = date.diff(s.updated_at,date.epoch()):spanseconds(),
          ctime = date.diff(s.created_at,date.epoch()):spanseconds(),
        }
      end
    end
    local ok, res = ngx.thread.wait(red_func)
    if res == false then
      ngx_exit(ngx_error)
    end
    ngx_exit(ngx.OK)
  end
end

function IRCServer:getState()
  return {
    users = from_json(to_json(self.users)),
    rooms = from_json(to_json(self.rooms)),
  }
end

function IRCServer:processViewCountResult(update)
  local stream = Stream:find({ id = update.stream_id })
  local account = Account:find({ id = update.account_id })
  account.network = networks[account.network]

  local roomName = slugify(stream:get_user().username) .. '-' .. stream.slug
  local accountName = slugify(account.network.name) .. '-' .. account.slug

  if self.users[accountName] then
    self.users[accountName].viewer_count = update.viewer_count
  end
end

function IRCServer:processWriterResult(update)
  local stream = Stream:find({ id = update.stream_id })
  local account = Account:find({ id = update.account_id })
  local og_account = Account:find({ id = update.cur_stream_account_id })
  account.network = networks[account.network]

  local roomName = slugify(stream:get_user().username) .. '-' .. stream.slug
  local accountUsername

  local c = 0
  for _,sa in pairs(stream:get_streams_accounts()) do
    local acc = sa:get_account()
    if acc.network == account.network.name then
      c = c + 1
    end
  end

  if c == 1 then
    accountUsername = slugify(account.network.name) .. '-' .. account.slug
  else
    accountUsername = slugify(account.network.name) .. '-' .. account.slug .. '-' .. og_account.slug
  end

  if not self.users[accountUsername] then
    self.users[accountUsername] = {
      user = {
        nick = accountUsername,
        username = accountUsername,
        realname = accountUsername,
      },
      account_id = account.id,
      cur_stream_account_id = og_account.id,
      network = account.network,
    }
  end

  if not self.rooms[roomName].users[accountUsername] then
    self.rooms[roomName].users[accountUsername] = true
    for u,user in pairs(self.rooms[roomName].users) do
      if self.users[u] and self.users[u].socket then
        self:sendRoomJoin(u,accountUsername,roomName)
      end
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
        cur_stream_account_id = account.id,
        network = account.network,
        viewer_count = nil,
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
  self.rooms[roomName].live = true
  self:sendRoomTopic(roomName)
  if config.irc_force_join then
    if not self.rooms[roomName].users[slugify(user.username)] and self.users[slugify(user.username)] then
      local ok, err = publish('irc:events:join', {
        nick = slugify(user.username),
        room = roomName,
      })
    end
  end
end

function IRCServer:processStreamUpdate(update)
  local stream = Stream:find({ id = update.id })
  local user = stream:get_user()
  local roomName = slugify(user.username) .. '-' ..stream.slug
  local room = self.rooms[roomName]
  if not room then -- slug has changed and/or brand-new stream
    room = {
      user_id = user.id,
      stream_id = stream.id,
      topic = 'Status: offline',
      live = false,
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
      room.live = oldroom.live
      room.topic = oldroom.topic
      for u,_ in pairs(oldroom.users) do
        -- only copy bots
        if self.users[u].network then
          room.users[u] = true
        end
        if self.users[u].socket then
          self:sendFromClient(u,'root','KICK','#'..oldroomName,u,'Room moving to #'..roomName)
          if room.live and config.irc_force_join then
            local ok, err = publish('irc:events:join', {
              nick = u,
              room = roomName,
            })
          end
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
  -- a comment:in can be for local IRC
  if update.type == 'emote' then
    update.text = char(1) .. 'ACTION '..update.text..char(1)
  end

  if update.user_id then
    if not self.user then return end
    if self.user.id == update.user_id and self.uuid ~= update.uuid then
      self:sendPrivMessage(self.user.nick,update.from.name,self.user.nick,update.text)
    end
    return
  end

  local username
  local stream = Stream:find({ id = update.stream_id })
  local user = stream:get_user()
  local roomname = slugify(user.username) .. '-' .. stream.slug

  if update.account_id == 0 then
    username = update.from.name
  else
    username = slugify(update.from.name) .. '-' .. update.network
  end

  if (not(update.uuid) or (update.uuid and update.uuid ~= self.uuid)) and self.socket and self.rooms[roomname].users[self.user.nick] then
    self:sendPrivMessage(self.user.nick,username,'#'..roomname,update.text)
  end

end

function IRCServer:processIrcJoin(msg)
  if not self.rooms[msg.room].users[msg.nick] then
    self.rooms[msg.room].users[msg.nick] = 0
  end
  self.rooms[msg.room].users[msg.nick] = self.rooms[msg.room].users[msg.nick] + 1

  if self.rooms[msg.room].users[msg.nick] == 1 then
    for to,_ in pairs(self.rooms[msg.room].users) do
      if self.users[to] and self.users[to].socket then
        self:sendRoomJoin(to,msg.nick,msg.room)
      end
    end
  end
end

function IRCServer:processIrcPart(msg)
  if self.rooms[msg.room] and self.rooms[msg.room].users[msg.nick] then
    self.rooms[msg.room].users[msg.nick] = self.rooms[msg.room].users[msg.nick] - 1
  end
  if not self.rooms[msg.room].users[msg.nick] or self.rooms[msg.room].users[msg.nick] == 0 then
    self.rooms[msg.room].users[msg.nick] = false
    for to,_ in pairs(self.rooms[msg.room].users) do
      if self.users[to].socket then
        self:sendRoomPart(to,msg.nick,msg.room,msg.message)
      end
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
      },
      conns = 0
    }
  end
  if not self.users[msg.nick].conns then
    self.users[msg.nick].conns = 0
  end
  self.users[msg.nick].conns = self.users[msg.nick].conns + 1
end

function IRCServer:processIrcLogout(msg)
  if self.users and self.users[msg.nick] then
    self.users[msg.nick].conns = self.users[msg.nick].conns - 1
    if self.users[msg.nick].conns == 0 then
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
  end
end

function IRCServer:processIrcMessage(msg)
  if msg.target:sub(1,1) == '#' then
    local room = msg.target:sub(2)
    if self.rooms[room] then
      for u,user in pairs(self.rooms[room].users) do
        if u ~= msg.nick and self.users[u] and self.users[u].socket then
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

function IRCServer:processIrcInvite(msg)
-- args: to from room
  if self.users[msg.to] and self.users[msg.to].socket then
    return self:sendFromClient(msg.to,msg.from,'INVITE',msg.to,':#'..msg.room)
  end
  return true,nil
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
    local chat_level = v.stream:check_chat(self.user)
    if chat_level > 0 then
      local count, list = self:userList(k)
      local ok, err = self:sendClientFromServer(
        nick,
        '322',
        '#'..k,
        count,
        v.topic)
      if not ok then return false,err end
    end
  end
  ok, err = self:sendClientFromServer(
    nick,
    '323',
    'End of /LIST')
  if not ok then return false,err end
  return true, nil
end

function IRCServer:clientIson(nick,msg)
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
  if resp:len() == 0 then
    resp = ':'
  end
  return self:sendClientFromServer(nick,'303',resp)
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

function IRCServer:clientInvite(nick,msg)
  if not msg.args[2] then
    return self:sendClientFromServer(nick,'461','INVITE','Not enough parameters')
  end
  local user = msg.args[1]
  local room = msg.args[2]:sub(2)

  if not self.users[user] or not self.rooms[room] then
    return self:sendClientFromServer(nick,'401',user,'No such nick/channel')
  end

  if self.rooms[room].users[user] then
    return self:sendClientFromServer(nick,'443',user,'#'..room,'is already on channel')
  end

  publish('irc:events:invite',{
    from = nick,
    to = user,
    room = room,
  })

  return self:sendClientFromServer(nick,'341',user,'#'..room)
end

function IRCServer:clientOper(nick,msg)
  return self:sendClientFromServer(nick,'464','Password incorrect')
end

function IRCServer:clientKick(nick,msg)
  return self:sendClientFromServer(nick,'482',msg.args[1],'You\'re not channel operator')
end

function IRCServer:clientTopic(nick,msg)
  return self:sendClientFromServer(nick,'482',msg.args[1],'You\'re not channel operator')
end

function IRCServer:clientUsers(nick,msg)
  return self:sendClientFromServer(nick,'446','USERS has been disabled')
end

function IRCServer:clientUnknown(nick,msg)
  return self:sendClientFromServer(nick,'421',msg.command:upper(),'Unknown command')
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
  local chat_level = self.rooms[room].stream:check_chat(self.user)
  if chat_level < 1 then
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
      local u = User:find({username = target})
      if u then
        self.users[target] = {
          user = u
        }
      else
        return self:sendClientFromServer(nick,'401','No such nick')
      end
    end
  end
  if room then
    self:checkBotCommand(nick,target,msg.args[2])
  end

  self:relayMessage(nick,room,target,msg.args[2])
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

function IRCServer:botCommandViewcount(nick,room,stream_nick)
  local message = ''
  local user = User:find({username = nick})
  if not stream_nick then
    for u,user in pairs(self.rooms[room].users) do
      if self.users[u] and self.users[u].account_id then
        if self.users[u].viewer_count ~= nil then
          publish('irc:events:message', {
            nick = u,
            target = '#'..room,
            message = self.users[u].viewer_count .. ' viewers'
          })
        else
          publish('irc:events:message', {
            nick = u,
            target = '#'..room,
            message = 'unknown viewers'
          })
        end
      end
    end
  else
    if not self.users[stream_nick] then
      botPublish(nick,room,'No such nick')
    elseif not self.users[stream_nick].account_id then
      botPublish(nick,room,'Not an active bot: ' .. stream_nick)
    else
      if self.users[stream_nick].viewer_count ~= nil then
        publish('irc:events:message', {
          nick = stream_nick,
          target = '#'..room,
          message = self.users[u].viewer_count .. ' viewers'
        })
      else
        publish('irc:events:message', {
          nick = u,
          target = '#'..room,
          message = 'unknown viewers'
        })
      end
    end
  end
end

function IRCServer:botCommandChatWriter(nick,room,target,account_slug)
  local message = ''
  if not target then
    botPublish(nick,room,'Missing parameters')
    botPublish(nick,room,'try !help chat')
    return
  end

  local user = User:find({username = nick})
  local target = target:lower()
  local stream = self.rooms[room]
  local network
  local tar_account_id
  local shortname = false

  if networks[target] then
    network = target
  elseif self.users[target] and self.users[target].cur_stream_account_id then
    network = self.users[target].network.name
    tar_account_id = self.users[target].cur_stream_account_id
  else
    botPublish(nick,room,'Not a network or bot: ' .. target)
    return
  end

  -- user checking what accounts are available
  if not account_slug or account_slug:len() == 0 then
    local accounts = Account:select(
        'where network = ? and user_id = ?',
        network,
        self.users[nick].user.id
    )
    local sas = SharedAccount:select(
      'where user_id = ?',
      self.users[nick].user.id)
    local message = 'Available accounts:'
    for i,account in ipairs(accounts) do
      message = message .. ' ' .. account.slug
    end
    for i,sa in ipairs(sas) do
      local account = sa:get_account()
      if account.network == self.users[stream_nick].network.name and
         account.id ~= self.users[stream_nick].account_id then
        message = message .. ' ' .. account.slug
      end
    end
    botPublish(nick,room,message)
    return
  end

  if not tar_account_id then
    -- see if there's only 1 account for the network
    local l_network = {}
    local c = 0
    local stream = self.rooms[room].stream
    for _,sa in pairs(stream:get_streams_accounts()) do
      local acc = sa:get_account()
      if acc.network == network then
        insert(l_network,acc)
        c = c + 1
      end
    end
    if c == 1 then
      shortname = true
      tar_account_id = l_network[1].id
    end
  end

  if not tar_account_id then
    botPublish(nick,room,'Please specify a bot instead of a network')
    return
  end
  local tar_account = Account:find({id = tar_account_id})

  if self.rooms[room].users[network .. '-' .. account_slug] or self.rooms[room].users[network .. '-' .. account_slug .. '-' .. tar_account.slug] then
    botPublish(nick,room,'Relay bot already exists')
    return
  end

  local account = Account:find({network = network, slug = account_slug })
  if not account then
    botPublish(nick,room,'Account not found')
    return
  end

  if not account:check_user(user) then
    botPublish(nick,room,'You can\'t use that account')
    return
  end

  publish('stream:writer', {
    worker = ngx.worker.pid(),
    account_id = account.id,
    user_id = self.users[nick].user.id,
    stream_id = self.rooms[room].stream_id,
    cur_stream_account_id = tar_account_id,
  })

end

function IRCServer:botCommandSummon(nick,room,stream_nick,account_slug)
  local message = ''
  local user = User:find({username = nick})
  if not stream_nick then
    botPublish(nick,room,'Missing parameters')
    botPublish(nick,room,'try !help summon')
    return
  end

  if not self.users[stream_nick] then
    botPublish(nick,room,'No such nick')
    return
  end

  if self.users[stream_nick].user and not self.users[stream_nick].account_id then
    if not self.rooms[room].users[stream_nick] then
      publish('irc:events:join', {
        nick = stream_nick,
        room = room,
      })
    else
      botPublish(nick,room,'That user is already here')
    end
    return
  end
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

function IRCServer:relayMessage(nick,isroom,target,message)
  local t = 'text'
  local message = message

  -- check if this is a CTCP ACTION (aka emote)
  if message:byte(1) == 1 then
    local m = message:sub(2,message:len()-1)
    local p = m:split(' ')
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
    markdown = message:escape_markdown(),
    from = {
        name = self.user.nick,
        id = self.user.id,
    }
  }

  if not isroom then
    m.user_id = self.users[target].user.id
    m.user_nick = target
    publish('comment:in',m)
    return
  end

  m.stream_id = self.rooms[target].stream_id

  if(message:sub(1,1) == '@') then
    message = message:sub(2)
  end

  local i = message:find(' ')
  if not i then
    publish('comment:in',m)
    return
  end

  local username = message:sub(1,i-1):lower()
  username = username:gsub('[^a-z]$','')
  local msg = message:sub(i+1)
  if msg:len() == 0 then
    publish('comment:in',m)
    return
  end

  publish('comment:in',m)

  if self.users[username] and self.users[username].account_id and self.rooms[target].users[username] == true then
    local account = Account:find({id = self.users[username].account_id})
    local user_ok = account:check_user(self.users[nick].user)
    local chat_level = self.rooms[target].stream:check_chat(self.users[nick].user)
    if user_ok or chat_level == 2 then
      if self.users[username].network.write_comments then
        m.network = nil
        m.from = nil
        m.uuid = nil
        m.markdown = nil
        m.account_id = self.users[username].account_id
        m.cur_stream_account_id = self.users[username].cur_stream_account_id
        m.text = msg
        publish('comment:out', m)
      else
        publish('irc:events:message',{
          nick = username,
          target = '#' .. target,
          message = nick .. ': not supported',
        })
      end
    else
      publish('irc:events:message',{
        nick = username,
        target = '#' .. target,
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
  if not message:find(' ') then
    message = ':' .. message
  end
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
  ngx_log(ngx_debug,msg)
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
  if self.users[nick] and self.users[nick].socket then
    ngx_log(ngx_debug,msg)
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
      ngx_exit(ngx_error)
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
            insert(send_buffer,':{hostname} 900 {nick} {nick}!{nick}@{hostname} {account} :You are now logged in as {nick}')
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
    insert(send_buffer,':{hostname} 001 {nick} :Welcome {nick}!{nick}@{hostname}')
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
      username = nickname,
      realname = realname,
    }
    return true, u
  end
  return false, 'login failed'
end

return IRCServer
