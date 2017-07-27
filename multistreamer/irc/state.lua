--[[
This module subscribes to events and processes them. It updates
the current IRC state, and when new clients connect they copy
their IRC state from this.

After processing updates, it returns a table of notable events,
then the IRC server can react to those events (ie, sending a message
to its client, putting its client into a room, etc).

The client will call something like

ok, events = IRCState.stateFunctions[endpoint_name)](data)
for i,event in ipairs(events) do
  if event.type == whatever do
    stuff
  end
end

]]

--[[ events generated:

userConnection    -- generated on any new connection by a user, web or IRC
  * state change, affects self.users

userLogin         -- generated on a user's first connection via web or IRC
  * no state change (that was handled by userConnection)

userDisconnection -- generated anytime a user disconnects, via web or IRC
  * state change, affects self.users

userLogout        -- generated when a user has no more connections, via web or IRC
  * no state change (that was handled by userConnection)

roomCreate        -- generated when a room is created
  * state change, affects self.rooms

roomUpdate        -- generated when the topic/live status of a room updates
  * state change, affects self.rooms[roomName]

roomDelete        -- generated when a room is deleted
  * state change, affects self.rooms[roomName]

roomMove          -- generated when a room is moved (technically, deleted + created)
  * state change, affects self.rooms[roomName]

roomJoin          -- generated when someone joins a room for the first time, web or IRC
  * state change, affects self.rooms[roomName].users

roomConnJoin      -- generated anytime someone joins a room, any connection
  * state change, affects self.users[username].connections[connid].rooms

roomPart          -- generated when someone parts a room
  * state change, affects self.rooms[roomName].users

roomConnPart      -- generated when someone parts a room, any connection
  * state change, affects self.users[username].connections[connid].rooms

writerAvailable   -- generated when a writer-bot is created
  * state change, affects self.bots

viewcountUpdate   -- generated when a stream's viewcounts are updated

ircInvite         -- generated when a user is invited to a channel
  * no state change, client can publish an 'irc:events:join' to trigger state-change

ircMessage        -- generated when a new message is created
  * no state change, client can publish an 'irc:events:join' to trigger state-change

note: roomcreate/update/etc do NOT have leading pound signs in roomName

]]

--[[ event structures:

userConnection:
  type = 'userConnection'
  username = some-username
  connid = connid

userLogin:
  type = 'userConnection'
  username = some-username

userDisconnection:
  type = 'userDisconnection'
  username = some-username
  connid = connid

userLogout:
  type = 'userConnection'
  username = some-username

roomCreate:
  type = 'roomCreate'
  roomName = roomName

roomDelete:
  type = 'roomCreate'
  roomName = roomName

roomUpdate:
  type = 'roomUpdate',
  roomName = roomName,
  topic = topic,
  live = true/false

roomMove:
  type = 'roomMove',
  roomName = roomName,
  oldRoomName = oldRoomName,

roomJoin
  type = 'roomJoin',
  roomName = roomName,
  username = username,

roomConnJoin
  type = 'roomConnJoin',
  roomName = roomName,
  username = username,
  connid = connid,

roomPart
  type = 'roomPart',
  roomName = roomName,
  username = username,

roomConnPart
  type = 'roomConnPart',
  roomName = roomName,
  username = username,
  connid = connid,

writerAvailable:
  type = 'writerAvailable',
  roomName = roomName,
  username = accountUsername,

viewcountUpdate:
  type = 'viewcountUpdate',
  roomName = roomName,
  username = accountName,
  viewcount = viewer_count,

ircInvite:
  type = 'ircInvite',
  from = from
  to = to
  room = room (includes beginning '#' sign)

ircMessage:
  type = 'ircMessage',
  from = from
  to = to (includes beginning '#' sign for rooms, remains plain for usersnames)
  text = text,
]]

-- luacheck: globals ngx uuid
local ngx = ngx
local uuid = uuid

local date = require'date'
local slugify = require('lapis.util').slugify
local to_json = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local User = require'models.user'
local Stream = require'models.stream'
local Account = require'models.account'

local string = require'multistreamer.string'
local char = string.char
local sub = string.sub
local insert = table.insert
local pairs = pairs
local ipairs = ipairs
local ngx_log = ngx.log
local ngx_exit = ngx.exit
local ngx_error = ngx.ERROR
local ngx_err = ngx.ERR

local redis = require'multistreamer.redis'
local endpoint = redis.endpoint
local subscribe = redis.subscribe
local publish = redis.publish

local function getRoomName(stream)
  return slugify(stream:get_user().username) .. '-' .. stream.slug
end

local IRCState = {}
IRCState.__index = IRCState

function IRCState.new()
  local server = {
    ready = false,
    uuid = uuid(),
  }
  -- keep track of all rooms in a global server.rooms table
  -- server.rooms = {
  --   ['roomName'] = {
  --     stream_id = stream.id,
  --     users = {
  --       ['nick'] = {
  --         id = user.id,
  --       },
  --     bots = {
  --       ['nick'] = {
  --         account_id = account.id,
  --         tar_account_id = tar_account.id,
  --         viewer_count = viewer_count,
  --       }
  --     }
  --   }
  -- }
  --
  -- Notes for the bots:
  --   account_id = the account id the message is *from*
  --   tar_account_id = the account id of the target stream
  --   example: say I'm streaming to 2 twitch accounts, ids 5 and 6
  --   and I have a twitch account not streaming right now, is 7
  --
  --   to send a message from 7 to 5's channel, I use
  --   account_id = 7
  --   tar_account_id = 5
  --
  --   to send a message from 5 to 5's channel (my own channel),
  --   account_id = 5
  --   tar_account_id = 5
  --
  -- keep track of all users in a global server.users table
  -- server.users = {
  --   ['username'] = {
  --     id = user.id,
  --     connections = {
  --       ['conn_uuid'] = {
  --         rooms = {
  --           ['roomName'] = true,
  --         }
  --       }
  --     }
  --   }
  -- }
  --
  -- a user can have multiple connections, so this keeps
  -- track of per-connectionr rooms, and updated the
  -- global rooms tables when a user gets its first
  -- reference to that room, or loses its last reference
  -- to that room
  --
  -- there's an implied 'root' user in every room for
  -- responding to commands, etc.

  server.rooms = {}
  server.users = {}
  setmetatable(server,IRCState)
  return server
end

-- the updateState function is called by active IRC servers
function IRCState:updateState(endpointName,params)
  local func = self.redisFunctions[endpointName]

  if func then
    return func(self,params)
  end
  return nil
end

-- also called by active IRC servers
function IRCState.createSubscriptions(red)
  local ok
  if not red then
    ok, red = subscribe('irc:events:login')
    if not ok then
      return false, nil
    end
  else
    subscribe('irc:events:login',red)
  end
  subscribe('irc:events:logout',red)
  subscribe('irc:events:join',red)
  subscribe('irc:events:part',red)
  subscribe('irc:events:message',red)
  subscribe('irc:events:invite',red)
  subscribe('irc:events:summon',red)
  subscribe('stream:start',red)
  subscribe('stream:end',red)
  subscribe('stream:update',red)
  subscribe('stream:delete',red)
  subscribe('stream:writerresult',red)
  subscribe('stream:viewcountresult',red)
  subscribe('comment:in',red)

  return true, red
end

function IRCState:run()
  -- build initial state
  for _,u in ipairs(User:select()) do
    self:createUser(u)
    for _,s in ipairs(u:get_streams()) do
      self:createRoom(s)
    end
  end

  local ok, red = IRCState.createSubscriptions()
  if not ok then
    ngx_exit(ngx_error)
  end

  self.ready = true

  while true do
    local res, err = red:read_reply()
    if err and err ~= 'timeout' then
      ngx_log(ngx_err,'[IRCState] Redis disconnected!')
      self.ready = false
      return false
    end
    if res then
      self:updateState(res[2],from_json(res[3]))
    end
  end
end

function IRCState:getUsers()
  return from_json(to_json(self.users))
end

function IRCState:getRooms()
  return from_json(to_json(self.rooms))
end

function IRCState:createUser(user, connid, irc, res)
  res = res or {}

  if not self.users[user.username] then
    self.users[user.username] = {
      id = user.id,
      connections = {},
      irc = irc,
    }

    insert(res, {
      type = 'userLogin',
      username = user.username,
      id = user.id,
    })
  end

  if connid and not self.users[user.username].connections[connid] then
    self.users[user.username].connections[connid] = {
      rooms = {},
      irc = irc,
    }

    insert(res, {
      type = 'userConnection',
      username = user.username,
      connid = connid,
    })
  end

  -- set the global 'irc' flag
  for _,conn in pairs(self.users[user.username].connections) do
    if conn.irc then
      self.users[user.username].irc = true
      break
    end
  end

  return true, res
end

function IRCState:deleteUser(user, connid, message, res)
  res = res or {}

  if not self.users[user.username] then
    return true, res
  end

  if self.users[user.username].connections[connid] then
    for roomName,_ in pairs(self.users[user.username].connections[connid].rooms) do
      IRCState.partRoom(self,user,roomName,connid,message,res)
    end

    self.users[user.username].connections[connid] = nil

    insert(res, {
      type = 'userDisconnection',
      username = user.username,
      connid = connid,
    })
  end

  self.users[user.username].irc = false

  for _,conn in pairs(self.users[user.username].connections) do
    if conn.irc then
      self.users[user.username].irc = true
      break
    end
  end

  -- check there's no more connections, period
  local c = 0
  for _,_ in pairs(self.users[user.username].connections) do
    c = c + 1
  end

  if c > 0 then
    return true, res
  end

  self.users[user.username] = nil
  for _,room in pairs(self.rooms) do
    room.users[user.username] = nil
  end

  insert(res, {
      type = 'userLogout',
      username = user.username,
      connid = connid,
      message = message
  })

  return true, res
end

function IRCState:createRoom(stream, res)
  res = res or {}

  local roomName = getRoomName(stream)

  if self.rooms[roomName] then
    return true, res
  end

  self.rooms[roomName] = {
    stream_id = stream.id,
    mtime = date.diff(stream.updated_at,date.epoch()):spanseconds(),
    ctime = date.diff(stream.created_at,date.epoch()):spanseconds(),
    topic = 'Status: offline',
    live = false,
    users = {},
    bots = {},
  }
  insert(res, {
    type = 'roomCreate',
    roomName = roomName,
  })

  return true, res
end

function IRCState:joinRoom(user,roomName,connid,res)
  res = res or {}

  IRCState.createUser(self, user, connid, nil, res)

  if not self.rooms[roomName].users[user.username] then
    self.rooms[roomName].users[user.username] = {
      id = user.id
    }
    insert(res, {
      type = 'roomJoin',
      roomName = roomName,
      username = user.username,
    })
  end

  if not self.users[user.username].connections[connid].rooms[roomName] then
    self.users[user.username].connections[connid].rooms[roomName] = true
    insert(res, {
      type = 'roomConnJoin',
      roomName = roomName,
      username = user.username,
      connid = connid,
    })
  end

  return true, res
end

function IRCState:partRoom(user,roomName,connid,message,res)
  res = res or {}
  message = message or 'Leaving'

  IRCState.createUser(self, user, connid, nil, res)

  self.users[user.username].connections[connid].rooms[roomName] = nil
  insert(res, {
    type = 'roomConnPart',
    roomName = roomName,
    username = user.username,
    connid = connid,
    message = message,
  })

  -- check there's no connections using that room
  for _,conn in pairs(self.users[user.username].connections) do
    for k,_ in pairs(conn.rooms) do
      if k == roomName then
        return true, res
      end
    end
  end

  -- no connections using that room
  self.rooms[roomName].users[user.username] = nil
  insert(res, {
    type = 'roomPart',
    roomName = roomName,
    username = user.username,
    message = message,
  })

  return true, res

end

function IRCState:createWriter(stream, account, tar_account, res)
  res = res or {}

  -- make sure a room exists
  IRCState.createRoom(self, stream, res)

  local roomName = getRoomName(stream)
  local accountUsername

  -- check if we're streaming to multiples of the same network
  local c = 0
  for _,sa in pairs(stream:get_streams_accounts()) do
    local acc = sa:get_account()
    if acc.network == account.network then
      c = c + 1
    end
  end

  if c == 1 or account.id == tar_account.id then
    accountUsername = slugify(account.network) .. '-' .. account.slug
  else
    accountUsername = slugify(account.network) .. '-' .. account.slug .. '-' .. tar_account.slug
  end

  if not self.rooms[roomName].bots[accountUsername] then
    self.rooms[roomName].bots[accountUsername] = {
      account_id = account.id,
      tar_account_id = tar_account.id,
      network = account.network,
    }
    insert(res, {
      type = 'writerAvailable',
      roomName = roomName,
      username = accountUsername,
    })
  end

  return true, res
end

-- endpoint('stream:writerresult')
function IRCState:processWriterResult(update, res)
  res = res or {}

  -- first check that we have a room for this writer
  -- (we should, but just in case)
  local stream = Stream:find({ id = update.stream_id })
  if not stream then return false, res end

  -- double-check accounts exist
  local account = Account:find({ id = update.account_id })
  if not account then return false, res end

  local tar_account = Account:find({ id = update.cur_stream_account_id })
  if not tar_account then return false, res end

  return IRCState.createWriter(self, stream, account, tar_account)
end


function IRCState:processViewCountResult(update,res)
  res = res or {}

  -- {
  --   stream_id,
  --   account_id,
  --   viewer_count,
  --}

  local stream = Stream:find({ id = update.stream_id })
  if not stream then return false, res end

  local account = Account:find({ id = update.account_id })
  if not account then return false, res end

  if IRCState.createWriter(self, stream, account, account, res) then
    local roomName = getRoomName(stream)
    local accountName = slugify(account.network) .. '-' .. account.slug
    self.rooms[roomName].bots[accountName].viewer_count = update.viewer_count
    insert(res, {
      type = 'viewcountUpdate',
      roomName = roomName,
      username = accountName,
      viewcount = update.viewer_count,
    })
  end

  return true, res
end

-- endpoint('comment:in')
function IRCState:processCommentUpdate(update, res)
  res = res or {}
  if not self.user then return true, res end

  --[[
  {
    from = {
      name = username,
      id = user_id
    },
    to = { -- optional, only on PMs/whispers
      id = user_id,
      name = username,
    },
    account_id (0 for IRC messages),
    type = 'text' or 'emote',
    network = network,
  }
  --]]

  -- a comment:in can be for local IRC
  if update.type == 'emote' then
    update.text = char(1) .. 'ACTION '..update.text..char(1)
  end

  if update.uuid == self.uuid then
    -- don't want to echo-back messages made from IRC
    return true, res
  end

  local msg_from, msg_to

  if update.to then
    if self.user.id == update.to.id or
       (self.user.id == update.from.id and self.uuid ~= update.uuid) then
      -- IRC PM
      msg_from = update.from.name
      msg_to = self.user.id == update.to.id and self.user.username or update.to.name
      insert(res, {
        type = 'ircMessage',
        from = msg_from,
        to = msg_to,
        text = update.text,
      })
      return true, res
    elseif not update.to.id then
      -- twitch IRC whisper
      update.text = '(whisper to ' .. update.to.name .. ') ' .. update.text
    end
  end

  if not msg_to and not update.stream_id then -- luacheck: ignore
    return false, res
  end

  local stream = Stream:find({ id = update.stream_id })
  if not stream then return false, res end

  local roomName = getRoomName(stream)
  if not self.user.rooms[roomName] then
    return true, res
  end

  msg_to = '#' .. roomName

  if not msg_from then -- luacheck: ignore
    if update.account_id == 0 then
      msg_from = update.from.name
    else
      msg_from = slugify(update.from.name) .. '-' .. update.network
    end
  end

  insert(res, {
    type = 'ircMessage',
    from = msg_from,
    to = msg_to,
    text = update.text,
  })

  return true, res
end



-- endpoint('stream:start')
function IRCState:processStreamStart(update, res)
  res = res or {}

  if update.status.data_pushing ~= true then -- we only care once a stream goes live
    return true, res
  end

  local stream = Stream:find({ id = update.id })
  if not stream then return false, res end

  local sas = stream:get_streams_accounts()
  local roomName = getRoomName(stream)
  local topic = 'Status: live'

  IRCState.createRoom(self, stream, res)

  for _,sa in pairs(sas) do
    local http_url = sa:get('http_url')
    if http_url then
      topic = topic .. ' ' .. http_url
    end

    local account = sa:get_account()
    IRCState.createWriter(self, stream, account, account, res)
  end

  self.rooms[roomName].topic = topic
  self.rooms[roomName].live = true

  insert(res, {
    type = 'roomUpdate',
    roomName = roomName,
    topic = topic,
    live = true,
  })

  return true, res
end

-- endpoint('stream:delete')
function IRCState:processStreamDelete(update, res)
  res = res or {}

  -- can't look up the stream (it's been deleted),
  local roomName = slugify(update.user.username) .. '-' .. update.slug

  if not self.rooms[roomName] then return true, res end
  self.rooms[roomName] = nil

  insert(res, {
    type = 'roomDelete',
    roomName = roomName,
  })

  return true, res
end

-- endpoint('stream:update')
function IRCState:processStreamUpdate(update, res)
  res = res or {}

  local stream = Stream:find({ id = update.id })
  if not stream then return false, res end

  local roomName = getRoomName(stream)
  if not self.rooms[roomName] then -- this could be a new room or a rename
    local oldRoomName
    for k,v in pairs(self.rooms) do
      if v.stream_id == stream.id then
        oldRoomName = k
      end
    end

    if oldRoomName == nil then
      return IRCState.createRoom(self, stream,res)
    end

    -- create room but don't include it in res
    IRCState.createRoom(self, stream)
    -- copy items from the oldRoomName to newRoomName
    self.rooms[roomName].live = self.rooms[oldRoomName].live
    self.rooms[roomName].topic = self.rooms[oldRoomName].topic

    for username,_ in pairs(self.rooms[oldRoomName].bots) do
      self.rooms[roomName].bots[username] = {}
      self.rooms[roomName].bots[username].account_id = self.rooms[oldRoomName].bots[username].account_id
      self.rooms[roomName].bots[username].tar_account_id = self.rooms[oldRoomName].bots[username].tar_account_id
    end

    for username,_ in pairs(self.rooms[oldRoomName].users) do
      self.rooms[roomName].users[username] = {}
      self.rooms[roomName].users[username].id = self.rooms[oldRoomName].users[username].id
    end

    -- update connection references to use the new room
    for _,user in pairs(self.users) do
      for _,connection in pairs(user.connections) do
        if connection.rooms[oldRoomName] then
          connection.rooms[oldRoomName] = nil
          connection.rooms[roomName] = true
        end
      end
    end

    self.rooms[oldRoomName] = nil

    insert(res, {
      type = 'roomMove',
      roomName = roomName,
      oldRoomName = oldRoomName,
    })
  end

  return true, res
end

-- endpoint('stream:end')
function IRCState:processStreamEnd(update,res)
  res = res or {}

  local stream = Stream:find({ id = update.id })
  if not stream then return false, res end

  local roomName = getRoomName(stream)

  -- make all bots part room
  for u,_ in pairs(self.rooms[roomName].bots) do
    insert(res, {
      type = 'roomPart',
      roomName = roomName,
      username = u,
    })
  end

  self.rooms[roomName].bots = {}
  self.rooms[roomName].topic = 'Status: offline'
  self.rooms[roomName].live = false

  insert(res, {
    type = 'roomUpdate',
    roomName = roomName,
    topic = self.rooms[roomName].topic,
    live = false,
  })

  return true, res
end

-- endpoint('irc:events:join')
function IRCState:processIrcJoin(msg, res)
  res = res or {}

  -- message structure:
  -- {
  --   nick = nick,
  --     user_id = user_id,
  --   uuid = uuid,
  --   room = room,
  -- }
  --
  local user = {
    id = msg.user_id,
    username = msg.nick,
  }

  return IRCState.joinRoom(self,user,msg.room,msg.uuid,res)
end

-- endpoint('irc:events:part')
function IRCState:processIrcPart(msg, res)
  res = res or {}

  -- message structure:
  -- {
  --   nick = nick,
  --   uuid = uuid,
  --   room = room,
  --   message = message
  -- }

  local user = User:find({ username = msg.nick })
  if not user then return false, res end

  return IRCState.partRoom(self, user,msg.room,msg.uuid,msg.message,res)
end

-- endpoint('irc:events:login')
function IRCState:processIrcLogin(msg, res)
  res = res or {}

  -- message structure:
  -- {
  --   nick = nick,
  --   user_id = user_id,
  --   uuid = uuid,
  --   irc = true/false,
  -- }

  local user = {
    id = msg.user_id,
    username = msg.nick,
  }

  return IRCState.createUser(self, user, msg.uuid, msg.irc, res)
end

-- endpoint('irc:events:logout')
function IRCState:processIrcLogout(msg, res)
  res = res or {}

  -- message structure:
  -- {
  --   nick = nick,
  --   uuid = uuid,
  -- }

  local user = User:find({ username = msg.nick })
  if not user then return false, res end

  return IRCState.deleteUser(self,user,msg.uuid,msg.message or 'Leaving...',res)
end

function IRCState:processIrcMessage(msg, res)
  res = res or {}
  if not self.user then return true, nil end

  if sub(msg.target,1,1) == '#' then
    if not self.user.rooms[sub(msg.target,2)] then
      return false, res
    end
  elseif self.user.username ~= msg.target then
    return false, res
  end

  insert(res, {
    type = 'ircMessage',
    from = msg.nick,
    to = msg.target,
    text = msg.message,
    bot = msg.bot,
  })

  return true, res
end

function IRCState:processIrcInvite(msg, res)
  res = res or {}

  if not self.user then return true, nil end

  if self.user.username == msg.to and self.rooms[msg.room] then
    insert(res, {
      type = 'ircInvite',
      from = msg.from,
      to = msg.to,
      room = '#' .. msg.room,
    })
    return true, res
  end
  return false, res
end

function IRCState:processIrcSummon(msg, res)
  res = res or {}

  if not self.user then return true, nil end

  publish('irc:events:join',{
    nick = self.user.username,
    room = msg.room,
    uuid = self.uuid,
  })

  return true, res
end

function IRCState:isReady()
  return self.ready
end

IRCState.redisFunctions = {
  [endpoint('stream:start')] = IRCState.processStreamStart,
  [endpoint('stream:end')] = IRCState.processStreamEnd,
  [endpoint('stream:update')] = IRCState.processStreamUpdate,
  [endpoint('stream:delete')] = IRCState.processStreamDelete,
  [endpoint('stream:writerresult')] = IRCState.processWriterResult,
  [endpoint('stream:viewcountresult')] = IRCState.processViewCountResult,
  [endpoint('irc:events:login')] = IRCState.processIrcLogin,
  [endpoint('irc:events:logout')] = IRCState.processIrcLogout,
  [endpoint('irc:events:join')] = IRCState.processIrcJoin,
  [endpoint('irc:events:part')] = IRCState.processIrcPart,
  [endpoint('comment:in')] = IRCState.processCommentUpdate,
  [endpoint('irc:events:message')] = IRCState.processIrcMessage,
  [endpoint('irc:events:invite')] = IRCState.processIrcInvite,
  [endpoint('irc:events:summon')] = IRCState.processIrcSummon,
}

return IRCState
