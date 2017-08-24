-- luacheck: globals ngx
local ngx = ngx

local config = require'multistreamer.config'
local encode_query_string = require('lapis.util').encode_query_string
local encode_base64 = require('lapis.util.encoding').encode_base64
local decode_base64 = require('lapis.util.encoding').decode_base64
local encode_with_secret = require('lapis.util.encoding').encode_with_secret
local decode_with_secret = require('lapis.util.encoding').decode_with_secret
local to_json   = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local slugify = require('lapis.util').slugify
local http = require'multistreamer.http'
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'
local string = require'multistreamer.string'
local format = string.format
local len = string.len
local split = string.split
local sub = string.sub
local match = string.match
local find = string.find
local gsub = string.gsub
local to_table = string.to_table
local escape_markdown = string.escape_markdown
local insert = table.insert
local sort = table.sort
local tonumber = tonumber
local ngx_log = ngx.log
local ngx_err = ngx.ERR
local ngx_debug = ngx.DEBUG
local sleep = ngx.sleep

local IRCClient = require'multistreamer.irc.client'

local Account = require'models.account'
local StreamAccount = require'models.stream_account'

local M = {}

M.name = 'twitch'
M.displayname = 'Twitch'
M.allow_sharing = true
M.read_comments = true
M.write_comments = true
M.redirect_uri = config.public_http_url .. config.http_prefix .. '/auth/twitch'

M.icon =
  '<svg viewBox="0 0 16 16" xmlns="http://www.w3.or' ..
  'g/2000/svg" fill-rule="evenodd" clip-rule="evenodd" stroke-linejoin="rou' ..
  'nd" stroke-miterlimit="1.414"><g fill-rule="nonzero"><path d="M1.393 0L.' ..
  '35 2.783v11.13h3.824V16h2.088l2.085-2.088h3.13L15.65 9.74V0H1.394zm1.39 ' ..
  '1.39H14.26v7.653l-2.435 2.435H8l-2.085 2.085v-2.085H2.783V1.39z"/><path ' ..
  'd="M6.61 8.348H8V4.175H6.61v4.173zm3.824 0h1.39V4.175h-1.39v4.173z"/></g' ..
  '></svg>'

local api_url = 'https://api.twitch.tv/kraken'
local twitch_config = config.networks.twitch

local function http_error_handler(res)
  return from_json(res.body).message
end

local function twitch_api_client(access_token)
  local httpc = http.new(http_error_handler)

  local _request = httpc.request

  httpc.request = function(self,method,endpoint,params,headers,body)
    local url = api_url .. endpoint
    local req_headers = {
      ['Accept'] = 'application/vnd.twitchtv.v5+json',
    }
    if access_token then
      req_headers['Authorization'] = 'OAuth ' .. access_token
    end
    if headers then
      for k,v in pairs(headers) do
          req_headers[k] = v
      end
    end

    local res, err = _request(self,method,url,params,req_headers,body)
    if err then return false, err end
    return from_json(res.body)
  end

  httpc.get = function(self,endpoint,params,headers)
    return httpc.request(self,'GET',endpoint,params,headers)
  end
  httpc.put = function(self,endpoint,params,headers)
    return httpc.request(self,'PUT',endpoint,nil,headers,to_json(params))
  end

  setmetatable(httpc,httpc)

  return httpc,nil

end

function M.metadata_fields()
  return {
    [1] = {
        type = 'text',
        label = 'Title',
        key = 'title',
        required = true,
    },
    [2] = {
        type = 'text',
        label = 'Game',
        key = 'game',
        required = true,
    },
  }
end

function M.metadata_form(_, stream)

  local form = M.metadata_fields()
  for _,k in ipairs(form) do
    k.value = stream:get(k.key)
  end

  return form, nil
end


function M.get_oauth_url(user, stream_id)
  return format('%s/oauth2/authorize?',api_url)..
         encode_query_string({
           response_type = 'code',
           force_verify = 'true',
           redirect_uri = M.redirect_uri,
           client_id = twitch_config.client_id,
           state = encode_base64(encode_with_secret({ id = user.id, stream_id = stream_id })),
           scope = 'user_read channel_read channel_editor channel_stream chat_login',
         })
end

function M.register_oauth(params)
  if params.error_description then
    return false, nil, 'Twitch Error: ' .. params.error_description
  end
  if params.error then
    return false, nil, 'Twitch Error: ' .. params.error
  end

  local user, _ = decode_with_secret(decode_base64(params.state))

  if not user then
    return false, nil, 'Error: User not found'
  end

  if not params.code then
    return false, nil, 'Twitch Error: failed to get temporary client token'
  end

  local httpc = http.new(http_error_handler)

  local body = encode_query_string({
    client_id = twitch_config.client_id,
    client_secret = twitch_config.client_secret,
    redirect_uri = M.redirect_uri,
    code = params.code,
    state = params.state,
    grant_type = 'authorization_code',
  })

  local res, err = httpc:post(api_url .. '/oauth2/token', nil, nil, body)

  if err then return false, nil, err end

  local creds = from_json(res.body)

  local tclient = twitch_api_client(creds.access_token)
  local user_info, user_err = tclient:get('/user')

  if user_err then
    return false, nil, user_err
  end

  local channel_info, channel_err = tclient:get('/channel')
  if channel_err then
    return false, nil, channel_err
  end

  local sha1 = resty_sha1:new()
  sha1:update(format('%d',user_info._id))

  local network_user_id = str.to_hex(sha1:final())

  local account = Account:find({
    network = M.name,
    network_user_id = network_user_id,
  })

  if not account then
    account = Account:create({
      user_id = user.id,
      network = M.name,
      network_user_id = network_user_id,
      name = user_info.display_name,
      slug = slugify(user_info.name),
    })
  else
   -- this account might be owned by somebody else
    account:update({
      name = user_info.display_name,
      slug = slugify(user_info.name),
    })
  end

  -- since we may have just taken somebody's account, we'll update
  -- the access token, channel etc anyway but return an error
  account:set('token',creds.access_token)
  account:set('channel',channel_info.name)
  account:set('channel_id',channel_info._id)
  account:set('stream_key',channel_info.stream_key)

  if(account.user_id ~= user.id) then
    return false, nil, 'Error: Account already registered'
  end

  local sa = nil
  if user.stream_id then
    sa = StreamAccount:find({ account_id = account.id, stream_id = user.stream_id })
    if not sa then
      sa = StreamAccount:create({ account_id = account.id, stream_id = user.stream_id })
    end
  end

  return account, sa, nil
end

function M.publish_start(account, stream)
  local stream_o = stream

  account = account:get_all()
  stream = stream:get_all()

  local rtmp_url = gsub(twitch_config.ingest_server,'/+$','') .. '/'

  if account.stream_key then
    rtmp_url = rtmp_url .. account.stream_key
  else
    return false, 'unable to create rtmp url'
  end

  -- check required settings
  if not stream.title or
     len(stream.title) == 0 or
     not stream.game or
     len(stream.game) == 0 then
    return false, 'Twitch: missing required settings'
  end

  local tclient = twitch_api_client(account.token)
  local res, err = tclient:put('/channels/'..account.channel_id, {
    channel = {
      status = stream.title,
      game = stream.game,
    }
  }, {
    ['Content-Type'] = 'application/json'
  })

  if not res then
    if type(err) == 'table' then
      return false, err.error
    else
      return false, err
    end
  end

  stream_o:set('http_url','https://twitch.tv/' .. account.channel)
  stream_o:set('channel',account.channel)
  return rtmp_url, nil
end

function M.publish_stop(_, stream)
  stream:unset('http_url')

  return true
end

function M.check_errors(account)
  local token = account:get('token')

  if not token then return 'No OAuth token' end

  local channel_id = account:get('channel_id')

  if not channel_id then
    local tclient = twitch_api_client(token)
    local channel_info, err = tclient:get('/channel')
    if err then
      return err
    end
    account:set('channel_id', channel_info._id)
  end

  return false
end

function M.notify_update(_,_)
  return true
end

local function linkify(token)
  if not token then return '' end
  if find(token,"^https?://") then
    return format('[%s](%s)',token,token)
  else
    return escape_markdown(token)
  end
end

local function emojify(message,emotes)
  local msgTable = to_table(message)
  if not emotes then
    emotes = {}
  else
    emotes = split(emotes,'/')
  end
  for _,v in ipairs(emotes) do
    local t = find(v,':')
    if t then
      local emote = sub(v,1,t-1)
      local ranges = split(sub(v,t+1),',')
      for _,r in ipairs(ranges) do
        local b,e = match(r,'(%d+)-(%d+)')
        b = tonumber(b) + 1
        e = tonumber(e) + 1
        local alt_text = sub(message,b,e)
        for i=b,e,1 do
          msgTable[i] = nil
        end
        msgTable[b] = format('![%s](http://static-cdn.jtvnw.net/emoticons/v1/%s/1.0)',alt_text,emote)
      end
    end
  end

  local keys = {}

  for k,_ in pairs(msgTable) do
    insert(keys,k)
  end

  sort(keys)

  local cur_token = ''
  local outmsg = ''

  for _,k in ipairs(keys) do
    local text = msgTable[k]
    if len(text) > 1 then
      if len(cur_token) > 0 then
        outmsg = outmsg .. linkify(cur_token)
        cur_token = ''
      end
      outmsg = outmsg .. text
    else
      if text == ' ' then
        outmsg = outmsg .. linkify(cur_token) .. ' '
        cur_token = ''
      else
        cur_token = cur_token .. text
      end
    end
  end

  if len(cur_token) > 0 then
    outmsg = outmsg .. linkify(cur_token)
  end
  return outmsg
end

function M.create_viewcount_func(account, _, send)
  if not send then return nil end

  local tclient = twitch_api_client(account['token'])
  local viewRunning = true
  local viewcount_func, stop_viewcount_func

  viewcount_func = function()
    while viewRunning do
      local res, err = tclient:get('/streams/' .. account['channel_id'])
      if not err then
        if type(res.stream) == 'table' then
          send({viewer_count = tonumber(res.stream.viewers)})
        end
      end
      sleep(60)
    end
    return true
  end

  stop_viewcount_func = function()
    viewRunning = false
  end

  return viewcount_func, stop_viewcount_func

end

function M.create_comment_funcs(account, stream, send)
  local irc = IRCClient.new()
  local nick = account.channel:lower()
  local channel = '#' .. stream.channel:lower()
  local icons = {}
  local tclient = twitch_api_client()
  local my_user_id

  local function irc_connect()
    local ok, err
    ngx_log(ngx_debug,format('[%s] IRC: Connecting',M.displayname))
    ok, err = irc:connect('irc.chat.twitch.tv',6667)
    if not ok then
      ngx_log(ngx_err,format('[%s] IRC: Connection failed: %s',M.displayname,err))
      return false,err
    end
    ngx_log(ngx_debug,format('[%s] IRC: logging in as %s',M.displayname,nick))
    ok, err = irc:login(nick,nil,nil,'oauth:'..account.token)
    if not ok then
      ngx_log(ngx_err,format('[%s] IRC: Login for "%s" failed: %s',M.displayname,nick,err))
      return false,err
    end
    ngx_log(ngx_debug,format('[%s] IRC: logged in as %s',M.displayname,nick))
    irc:join(channel)
    irc:capreq('twitch.tv/tags')
    irc:capreq('twitch.tv/commands')
    return true, nil
  end

  local function getIcon(userid)
    if icons[userid] == nil then
      local icon_res = tclient:get('/users/' .. userid, nil, {
        ['Client-ID'] = twitch_config.client_id,
      })
      if icon_res then
        icons[userid] = icon_res.logo
      end
    end
    return icons[userid]
  end

  if send then
    local tclient_temp = twitch_api_client(account['token'])
    local user_info = tclient_temp:get('/user/')
    my_user_id = user_info._id
    icons[my_user_id] = user_info.logo
  end

  local function sendMsg(event,data)
    local msg = {
      from = {
        name = data.tags['display-name'],
        id = data.tags['user-id'],
      },
      text = data.message,
      markdown = emojify(data.message,data.tags.emotes),
    }
    if len(msg.from.name) == 0 then
      msg.from.name = data.from.nick
    end

    msg.from.picture = getIcon(msg.from.id)

    if data.to == nick then
      msg.to = {
        name = nick,
      }
    end

    ngx_log(ngx_debug,format('[%s] IRC: Received message from %s',M.displayname,msg.from.name))

    if event == 'message' then
      msg.type = 'text'
    elseif event == 'emote' then
      msg.type = 'emote'
    end
    send(msg)
  end

  local irc_ok, irc_err = irc_connect()
  if not irc_ok then return false, irc_err end

  local running = true

  local stop_func = function()
    running = false
    irc:quit()
  end

  local read_func = function()
    if send then
      irc:onEvent('message',sendMsg)
      irc:onEvent('emote',sendMsg)
    end
    while running do
      local cruise_ok, cruise_err = irc:cruise()

      if not running then
        ngx_log(ngx_debug,format('[%s] IRC Client ending normally for %s',M.displayname,nick))
        return true
      end

      if not cruise_ok then
        ngx_log(ngx_err,format('[%s] IRC Client error: %s, reconnecting',M.displayname,cruise_err))
      end

      local reconnect_ok, reconnect_err = irc_connect()

      if not reconnect_ok then
        ngx_log(ngx_err,format('[%s] IRC Client error: %s, giving up',M.displayname,reconnect_err))
        return false, reconnect_err
      end
    end
    return true
  end

  local write_func = function(message)
    if message.type == 'text' then
      irc:message(channel,message.text)
    elseif message.type == 'emote' then
      irc:emote(channel,message.text)
    end
    -- we don't get messages echo'd back
    -- from IRC, so we'll echo on our own here
    if send then
      local msg = {
        from = {
          name = account.channel,
          picture = getIcon(my_user_id),
        },
        text = message.text,
        markdown = escape_markdown(message.text),
        type = message.type,
      }
      send(msg)
    end
  end

  return read_func, write_func, stop_func
end

return M
