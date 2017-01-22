local config = require'helpers.config'
local encode_query_string = require('lapis.util').encode_query_string
local encode_base64 = require('lapis.util.encoding').encode_base64
local decode_base64 = require('lapis.util.encoding').decode_base64
local encode_with_secret = require('lapis.util.encoding').encode_with_secret
local decode_with_secret = require('lapis.util.encoding').decode_with_secret
local to_json   = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local slugify = require('lapis.util').slugify
local http = require'resty.http'
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'
local format = string.format
local len = string.len
local insert = table.insert
local concat = table.concat
local sort = table.sort
local tonumber = tonumber
local IRCClient = require'util.irc.client'

local Account = require'models.account'

local M = {}

M.displayname = 'Twitch'
M.allow_sharing = true

M.read_comments = true
M.write_comments = true

local api_uri = 'https://api.twitch.tv/kraken'
local twitch_config = config.networks.twitch

local function twitch_api_client(access_token)
  if not access_token then
    return false,'access_token required'
  end

  local t = {}
  t.httpc = http.new()
  t.access_token = access_token

  t.request = function(self,method,endpoint,params,headers,body)
    local uri = api_uri .. endpoint
    local req_headers = {
      ['Authorization'] = 'OAuth ' .. self.access_token,
      ['Accept'] = 'application/vnd.twitchtv.v3+json',
    }
    if params then
      uri = uri .. '?' .. encode_query_string(params)
    end
    if headers then
      for k,v in pairs(headers) do
          req_headers[k] = v
      end
    end

    local res, err = self.httpc:request_uri(uri, {
      method = method,
      headers = req_headers,
      body = body,
    })
    if body then ngx.log(ngx.DEBUG,body) end

    if err then
      return false, { error = err }
    end

    if res.status == 400 then
      return false, from_json(res.body)
    end

    return from_json(res.body), nil
  end

  t.get = function(self,endpoint,params,headers)
    return self:request('GET',endpoint,params,headers)
  end
  t.put = function(self,endpoint,params,headers)
    return self:request('PUT',endpoint,nil,headers,to_json(params))
  end

  return t,nil

end

local function update_ingest_endpoints(account)
  local endpoints = account:get('endpoints')
  if endpoints then
    endpoints = from_json(endpoints)
    return endpoints, nil
  else
    local tclient = twitch_api_client(account:get('token'))
    local res, err = tclient:get('/ingests/')
    if err then
      return false, err
    end
    endpoints = {}
    for _,v in pairs(res.ingests) do
      local k = format('%d',v._id)
      endpoints[k] = {
        name = v.name,
        url_template = v.url_template,
      }
    end
    account:set('endpoints',to_json(endpoints),  864000 )
    return endpoints, nil
  end
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
    [3] = {
        type = 'select',
        label = 'Stream Endpoint',
        key = 'endpoint',
        required = true,
    },
  }
end

function M.metadata_form(account, stream)

  local form = M.metadata_fields()
  for i,k in ipairs(form) do
    k.value = stream:get(k.key)
  end
  form[3].options = {}

  local endpoints, err = update_ingest_endpoints(account)
  if err then return false, err end

  for k,v in pairs(endpoints) do
    insert(form[3].options, {
      value = k,
      label = v.name
    })
  end

  sort(form[3].options,function(a,b)
    return a.label < b.label
  end)

  return form, nil
end


function M.get_oauth_url(user)
  return format('%s/oauth2/authorize?',api_uri)..
         encode_query_string({
           response_type = 'code',
           force_verify = 'true',
           redirect_uri = M.redirect_uri,
           client_id = twitch_config.client_id,
           state = encode_base64(encode_with_secret({ id = user.id })),
           scope = 'user_read channel_read channel_editor channel_stream chat_login',
         })
end

function M.register_oauth(params)
  if params.error_description then
    return false, 'Twitch Error: ' .. params.error_description
  end
  if params.error then
    return false, 'Twitch Error: ' .. params.error
  end

  local user, err = decode_with_secret(decode_base64(params.state))

  if not user then
    return false, 'Error: User not found'
  end

  if not params.code then
    return false, 'Twitch Error: failed to get temporary client token'
  end

  local httpc = http.new()
  local body = encode_query_string({
    client_id = twitch_config.client_id,
    client_secret = twitch_config.client_secret,
    redirect_uri = M.redirect_uri,
    code = params.code,
    state = params.state,
    grant_type = 'authorization_code',
  })

  local res, err = httpc:request_uri(api_uri .. '/oauth2/token', {
    method = 'POST',
    body = body,
  });

  if err or res.status >= 400 then
    return false, err
  end

  local creds = from_json(res.body)

  local tclient = twitch_api_client(creds.access_token)
  local user_info, err = tclient:get('/user')

  if err then
    return false, err
  end

  local channel_info, err = tclient:get('/channel')
  if err then
    return false, err
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
  account:set('stream_key',channel_info.stream_key)

  if(account.user_id ~= user.id) then
    return false, 'Error: Account already registered'
  end

  return account, nil
end

function M.publish_start(account, stream)
  local endpoints, err = update_ingest_endpoints(account)

  local stream_o = stream

  local account = account:get_all()
  local stream = stream:get_all()

  local rtmp_url

  if endpoints and endpoints[stream.endpoint] and account.stream_key then
    rtmp_url = endpoints[stream.endpoint].url_template:gsub('{stream_key}',account.stream_key)
  else
    return false, 'unable to create rtmp url'
  end

  local tclient = twitch_api_client(account.token)
  local res, err = tclient:put('/channels/'..account.channel..'/', {
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

function M.publish_stop(account, stream)
  stream:unset('http_url')

  return true
end

function M.check_errors(account)
  return false
end

function M.notify_update(account, stream)
  return true
end

local function emojify(message,emotes)
  local msgTable = message:to_table()
  local emotes = emotes:split('/')
  for i,v in ipairs(emotes) do
    local t = v:find(':')
    if t then
      local emote = v:sub(1,t-1)
      local ranges = v:sub(t+1):split(',')
      for _,r in ipairs(ranges) do
        local b,e = r:match('(%d+)-(%d+)')
        b = tonumber(b) + 1
        e = tonumber(e) + 1
        local alt_text = message:sub(b,e)
        for i=b,e,1 do
          msgTable[i] = nil
        end
        msgTable[b] = string.format('![%s](http://static-cdn.jtvnw.net/emoticons/v1/%s/3.0)',alt_text,emote)
      end
    end
  end
  local keys = {}
  local outmsg = {}
  for k,v in pairs(msgTable) do
    insert(keys,k)
  end
  sort(keys)
  for i,k in ipairs(keys) do
    insert(outmsg,msgTable[k])
  end
  return table.concat(outmsg,'')
end

function M.get_view_count(account, stream)
  local tclient = twitch_api_client(account['token'])
  local res, err = tclient:get('/streams/' .. account['channel'])
  if not err then
    if type(res.stream) == "table" then
      return res.stream.viewers
    end
  end
  return nil
end

function M.create_comment_funcs(account, stream, send)
  local irc = IRCClient.new()
  local nick = account.channel:lower()
  local channel = '#' .. stream.channel:lower()

  local function irc_connect()
    local ok, err
    ok, err = irc:connect('irc.chat.twitch.tv',6667)
    if not ok then
      ngx.log(ngx.ERR,err)
      return false,err
    end
    ok, err = irc:login(nick,nil,nil,'oauth:'..account.token)
    if not ok then
      ngx.log(ngx.ERR,err)
      return false,err
    end
    irc:join(channel)
    irc:capreq('twitch.tv/tags')
    return true, nil
  end

  local function sendMsg(event,data)
    if data.to ~= channel then return nil end
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
    if event == 'message' then
      msg.type = 'text'
    elseif event == 'emote' then
      msg.type = 'emote'
    end
    send(msg)
  end

  if not irc_connect() then return nil,nil end

  local read_func = function()
    local running = true
    if send then
      irc:onEvent('message',sendMsg)
      irc:onEvent('emote',sendMsg)
    end
    while running do
      local ok, err = irc:cruise()
      if not ok then ngx.log(ngx.ERR,'[Twitch] IRC Client error: ' .. err) end
      ok, err = irc_connect()
      if not ok then
        ngx.log(ngx.ERR,'[Twitch] IRC Connection error: ' .. err)
        running = false
      end
    end
    return false, nil
  end

  local write_func = function(message)
    irc:message(channel,message)
  end

  return read_func, write_func
end

return M
