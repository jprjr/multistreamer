-- luacheck: globals ngx
local ngx = ngx
local Account = require'models.account'
local StreamAccount = require'models.stream_account'
local config = require'multistreamer.config'
local encode_query_string = require('lapis.util').encode_query_string
local encode_base64 = require('lapis.util.encoding').encode_base64
local decode_base64 = require('lapis.util.encoding').decode_base64
local encode_with_secret = require('lapis.util.encoding').encode_with_secret
local decode_with_secret = require('lapis.util.encoding').decode_with_secret
local to_json   = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local ws_client = require "resty.websocket.client"
local string = require'multistreamer.string'
local escape_markdown = string.escape_markdown

local http = require'multistreamer.http'
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'
local slugify = require('lapis.util').slugify
local date = require'date'
local cjson = require'cjson'

local ngx_log = ngx.log

local tonumber = tonumber
local concat = table.concat
local len = string.len

local M = {}

M.name = 'mixer'
M.displayname = 'Mixer'
M.allow_sharing = true
M.read_comments = true
M.write_comments = true
M.redirect_uri = config.public_http_url .. config.http_prefix .. '/auth/mixer'

M.icon =
  '<svg version="1.1" xmlns="http://www' ..
  '.w3.org/2000/svg"  x="0px" y="0px" viewBox="0 0 512 512" style="enable-b' ..
  'ackground:new 0 0 512 512;" xml:space="preserve"><path class="st0" d="M1' ..
  '16.03,77.68c-15.76-21.29-46.72-24.61-66.91-6.36c-17.42,16.04-18.8,43.13-' ..
  '4.7,62.21l90.96,121.92 L43.87,378.48c-14.1,19.08-12.99,46.17,4.7,62.21c2' ..
  '0.18,18.25,51.15,14.93,66.91-6.36l127.73-171.69c3.04-4.15,3.04-9.95,0-14' ..
  '.1 L116.03,77.68z"/><path class="st1" d="M396.37,77.68c15.76-21.29,46.72' ..
  '-24.61,66.91-6.36c17.42,16.04,18.8,43.13,4.7,62.21l-90.96,121.92 l91.51,' ..
  '123.03c14.1,19.08,12.99,46.17-4.7,62.21c-20.18,18.25-51.15,14.93-66.91-6' ..
  '.36L269.47,262.36c-3.04-4.15-3.04-9.95,0-14.1 L396.37,77.68z"/></svg>'

local api_url = 'https://mixer.com/api/v1'

local function http_error_handler(res)
  return from_json(res.body).message
end

local function mixer_client(access_token)
  local httpc = http.new(http_error_handler)
  local _request = httpc.request

  httpc.request = function(self,method,endpoint,params,headers,body)
    params = params or {}
    local url = api_url .. endpoint
    local req_headers = {}
    if access_token then
      req_headers['Authorization'] = 'Bearer ' .. access_token
    end
    if headers then
      for k,v in pairs(headers) do
        req_headers[k] = v
      end
    end

    local res, err = _request(self,method,url,params,req_headers,body)
    if err then return nil, err end
    return from_json(res.body)
  end

  httpc.get = function(self,endpoint,params,headers)
    headers = headers or {}
    headers['Content-Type'] = 'application/x-www-form-urlencoded'
    return httpc.request(self,'GET',endpoint,params,headers)
  end

  httpc.getJSON = function(self,endpoint,params,headers)
    headers = headers or {}
    headers['Content-Type'] = 'application/json'
    return httpc.request(self,'GET',endpoint,params,headers)
  end

  httpc.post = function(self,endpoint,params,headers)
    local body = encode_query_string(params)
    headers = headers or {}
    headers['Content-Type'] = 'application/x-www-form-urlencoded'
    return httpc.request(self,'POST',endpoint,nil,headers,body)
  end

  httpc.postJSON = function(self,endpoint,params,headers)
    local body = to_json(params)
    headers = headers or {}
    headers['Content-Type'] = 'application/json'
    return httpc.request(self,'POST',endpoint,nil,headers,body)
  end

  httpc.patch = function(self,endpoint,params,headers)
    local body = encode_query_string(params)
    headers = headers or {}
    headers['Content-Type'] = 'application/x-www-form-urlencoded'
    return httpc.request(self,'PATCH',endpoint,nil,headers,body)
  end

  httpc.patchJSON = function(self,endpoint,params,headers)
    local body = to_json(params)
    headers = headers or {}
    headers['Content-Type'] = 'application/json'
    return httpc.request(self,'PATCH',endpoint,nil,headers,body)
  end

  httpc.__index = httpc
  setmetatable(httpc,httpc)
  return httpc
end

local function refresh_access_token(refresh_token, access_token, expires_in, expires_at)
  local do_refresh = false
  local now = date(true)

  if not access_token then
    do_refresh = true
  else
    local expires_at_dt = date(expires_at)
    if now > expires_at_dt then
      do_refresh = true
    end
  end

  if do_refresh == true then

    local httpc = mixer_client()
    local res, err = httpc:post('/oauth/token',
    {
      client_id = config.networks[M.name].client_id,
      client_secret = config.networks[M.name].client_secret,
      refresh_token = refresh_token,
      grant_type = 'refresh_token',
    })

    if err then
      return nil, err
    end

    local creds = res

    return creds.access_token, creds.expires_in, creds.refresh_token, now:addseconds(tonumber(creds.expires_in))
  else
    return access_token, expires_in, refresh_token, expires_at
  end
end

local function refresh_access_token_wrapper(account)
  local refresh_token = account['refresh_token']

  local access_token = account['access_token']
  local expires_in
  local expires_at

  if not access_token then
    access_token, expires_in, refresh_token, expires_at = refresh_access_token(account['refresh_token'])
  else
    expires_in = account['access_token.expires_in']
    expires_at = account['access_token.expires_at']
  end

  return access_token, expires_in, refresh_token, expires_at
end

function M.get_oauth_url(user,stream_id)
  return 'https://mixer.com/oauth/authorize?' ..
    encode_query_string({
      response_type = 'code',
      state = encode_base64(encode_with_secret({ id = user.id , stream_id = stream_id })),
      redirect_uri = M.redirect_uri,
      client_id = config.networks[M.name].client_id,
      scope = concat({
        'channel:details:self',
        'channel:streamKey:self',
        'channel:update:self',
        'chat:bypass_links',
        'chat:chat',
        'chat:connect',
        'recording:manage:self',
        'user:details:self',
      },' '),
    })
end

function M.register_oauth(params)
  local user, _ = decode_with_secret(decode_base64(params.state))

  if not user then
    return false, nil, 'Beam error: no user info sent'
  end

  if not params.code then
    return false, nil, 'Beam error: no temporary access code'
  end

  local httpc = mixer_client()
  local creds, creds_err = httpc:post('/oauth/token',
  {
    grant_type = 'authorization_code',
    code = params.code,
    client_secret = config.networks[M.name].client_secret,
    client_id = config.networks[M.name].client_id,
    redirect_uri = M.redirect_uri,
  })

  if creds_err then
    return false, nil, creds_err
  end

  httpc = mixer_client(creds.access_token)

  local user_info, user_err = httpc:get('/users/current')

  if user_err then
    return false, nil, user_err
  end

  local channel_info, channel_err = httpc:get('/channels/' .. user_info.channel.id .. '/details')

  if channel_err then
    return false, nil, channel_err
  end

  local sha1 = resty_sha1:new()
  sha1:update(string.format('%d',user_info.id))
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
      name = user_info.username,
      slug = slugify(user_info.username),
    })
  end

  account:set('access_token',creds.access_token,creds.expires_in)
  account:set('refresh_token',creds.refresh_token)
  account:set('channel_id', user_info.channel.id)
  account:set('user_id', user_info.id)
  account:set('stream_key',channel_info.streamKey)

  if account.user_id ~= user.id then
    return false, nil, "Account already registered"
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

function M.metadata_form(account, stream)
  M.check_errors(account)
  local form = M.metadata_fields()
  for _,v in pairs(form) do
    v.value = stream:get(v.key)
  end

  -- add in some default values etc to the form
  return form

end

function M.metadata_fields()
  return {
    [1] = {
      type = 'text',
      label = 'Stream Title',
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
      label = 'Target Audience',
      key = 'audience',
      required = true,
      options = {
        { label = 'Family Friendly', value = 'family' },
        { label = 'Teen', value = 'teen' },
        { label = '18+', value = '18+' },
      },
    }
  }
end

function M.publish_start(account, stream)
  local err = M.check_errors(account)
  if err then return false, err end

  local stream_o = stream

  account = account:get_all()
  stream = stream:get_all()

  local fields = M.metadata_fields()
  for _,f in ipairs(fields) do
    if f.required == true then
      if not stream[f.key] or len(stream[f.key]) == 0 then
        return false, 'Beam: missing field "' .. f.label ..'"'
      end
    end
  end

  local access_token = account['access_token']
  local channel_id = account['channel_id']
  local stream_key = account['stream_key']

  local title = stream['title']
  local game = stream['game']
  local audience = stream['audience']

  local rtmp_url = config.networks[M.name].ingest_server .. '/' .. channel_id .. '-' .. stream_key
  local httpc = mixer_client(access_token)

  local games, games_err = httpc:getJSON('/types?',
  {
    query = game,
    limit = 1,
  })

  if games_err then
    return false, games_err
  end

  local channel_info, channel_err = httpc:patchJSON('/channels/' .. channel_id ,
  {
      name = title,
      audience = audience,
      typeId = games[1].id,
  })

  if channel_err then
    return false, channel_err
  end

  local http_url = 'https://mixer.com/' .. channel_info.token
  stream_o:set('http_url',http_url)
  stream_o:set('channel_id',account['channel_id'])

  return rtmp_url, nil

end

function M.publish_stop()
  return true, nil
end

function M.check_errors(account)
  local access_token, exp, _
  access_token, _ = account:get('access_token')
  if access_token then
    return false, nil
  end

  local refresh_token = account:get('refresh_token')
  access_token, exp, refresh_token = refresh_access_token(refresh_token)

  if not access_token then
    return false, exp
  end

  account:set('access_token',access_token,exp)
  account:set('refresh_token',refresh_token)

  return false,nil
end

function M.notify_update()
  return true
end

function M.create_comment_funcs(account, stream, send)
  local read_func = nil
  local stop_func = nil

  local access_token = refresh_access_token_wrapper(account)

  local httpc = mixer_client(access_token)
  local chat_endpoints, chat_err = httpc:getJSON('/chats/' .. stream['channel_id'])

  if chat_err then
    return false, false, chat_err
  end

  local ws = ws_client:new()
  local ws_ok, ws_err = ws:connect(chat_endpoints.endpoints[1])

  if not ws_ok then
    ngx_log(ngx.ERR,'[Beam] Unable to connect to websocket: ' .. ws_err)
    return false, false, ws_err
  end

  local welcome_resp, _, err = ws:recv_frame()
  if not welcome_resp then
    return nil, nil, err
  end
  welcome_resp = from_json(welcome_resp)

  if welcome_resp.type ~= 'event' or welcome_resp.event ~= 'WelcomeEvent' then
    return nil,nil,'received unexpected event'
  end

  local auth = to_json({
    type = 'method',
    method = 'auth',
    arguments = { tonumber(stream['channel_id']), tonumber(account['user_id']), chat_endpoints['authkey'] },
    id = 0,
  })

  ws:send_text(auth)

  local auth_resp = ws:recv_frame()
  if not auth_resp then
    return nil, nil
  end
  auth_resp = from_json(auth_resp)

  if auth_resp.error ~= cjson.null then
    return nil, nil
  end

  if send then
    local readRunning = true
    read_func = function()
      while readRunning do
        local data, typ, _ = ws:recv_frame()
        if typ == 'text' then
          local msg = from_json(data)
          if msg.type == 'event' and msg.event == 'ChatMessage' then
            local txt = ""
            local msgtyp
            for _,v in ipairs(msg.data.message.message) do
              txt = txt .. v.text
            end
            if msg.data.message.meta.me then
              -- emote
              msgtyp = 'emote'
            elseif not msg.data.message.meta.whisper then
              msgtyp = 'text'
            end
            if msgtyp then
              send({
                type = msgtyp,
                from = {
                  name = msg.data.user_name,
                  id = msg.data.user_id,
                  picture = api_url .. '/users/' .. msg.data.user_id .. '/avatar?w=50'
                },
                text = txt,
                markdown = escape_markdown(txt),
              })
            end
          end
        end
      end
      return true
    end
    stop_func = function()
      readRunning = false
    end
  end

  local write_func = function(message)
    if message.type == 'emote' then
      message.text = '/me ' .. message.text
    end
    ws:send_text(to_json({
      type = 'method',
      method = 'msg',
      arguments = {
        message.text
      }
    }))
  end

  return read_func, write_func, stop_func
end

function M.create_viewcount_func(account, _, send)
  local access_token, expires_in, refresh_token, expires_at = refresh_access_token_wrapper(account)

  if not send then
    return nil
  end

  local viewcount_func, stop_viewcount_func
  local viewRunning = true

  viewcount_func = function()
    while viewRunning do
      access_token, expires_in, refresh_token, expires_at =
        refresh_access_token(refresh_token, access_token, expires_in, expires_at)
      if access_token then
        local httpc = mixer_client(access_token)
        local channel_info, channel_err = httpc:getJSON('/channels/' .. account['channel_id'])

        if channel_err then
          return false, channel_err
        end

        send({viewer_count = channel_info.viewersCurrent})
      end
      ngx.sleep(60)
    end
    return true
  end

  stop_viewcount_func = function()
    viewRunning = false
  end

  return viewcount_func, stop_viewcount_func
end

return M

