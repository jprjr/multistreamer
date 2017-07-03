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

local http = require'resty.http'
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'
local slugify = require('lapis.util').slugify
local date = require'date'
local cjson = require'cjson'

local ngx_log = ngx.log
local ngx_debug = ngx.DEBUG

local format = string.format
local tonumber = tonumber

local M = {}

M.displayname = 'Beam'
M.allow_sharing = true
M.read_comments = true
M.write_comments = true
M.icon = '<svg class="chaticon beam" version="1.1" id="Layer_1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" x="0px" y="0px" viewBox="0 0 116 116" style="enable-background:new 0 0 116 116;" xml:space="preserve"><g><path class="st0" d="M42.313591,73.686882c9.87011,9.870232,16.868416,21.591133,20.738979,34.056114 c23.68047-2.31514,42.375011-21.009331,44.690105-44.690105C95.27784,59.182278,83.556358,52.184048,73.686249,42.31382 L42.313591,73.686882z"/><path class="st1" d="M73.686249,42.31382l-0.000008-0.000008c-9.870106-9.870235-16.86813-21.59177-20.738693-34.056751 C29.267078,10.572195,10.572525,29.266369,8.257421,52.94714c12.464821,3.870613,24.186068,10.869499,34.056168,20.739735v0.000008 L73.686249,42.31382z"/><ellipse transform="matrix(0.707102 -0.707111 0.707111 0.707102 -24.02466 58.000568)" class="st2" cx="57.999916" cy="58.000351" rx="22.042198" ry="22.042198"/><path class="st3" d="M52.947548,8.257062c8.067341,26.088402,28.654411,46.712109,54.795128,54.79583 C110.907097,31.517778,84.43959,5.096885,52.947548,8.257062z"/><path class="st3" d="M63.05257,107.742996C54.985237,81.654587,34.39814,61.030861,8.257421,52.94714 C5.091702,84.495453,31.571623,110.902031,63.05257,107.742996z"/></g></svg>'

local api_url = 'https://beam.pro/api/v1'
local token_url = api_url .. '/oauth/token'

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

    local httpc = http.new()
    local res, err = httpc:request_uri(token_url, {
      method = 'POST',
      body = encode_query_string({
        client_id = config.networks[M.name].client_id,
        client_secret = config.networks[M.name].client_secret,
        refresh_token = refresh_token,
        grant_type = 'refresh_token',
      }),
      headers = {
        ['Content-Type'] = 'application/x-www-form-urlencoded',
      },
    })

    if err then
      return nil, err
    end

    if res and type(res.status) ~= 'number' then
      res.status = tonumber(res.status:find('^%d+'))
    end

    if res.status >= 400 then
      return nil, res.body
    end

    local creds = from_json(res.body)

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
  return 'https://beam.pro/oauth/authorize?' ..
    encode_query_string({
      response_type = 'code',
      state = encode_base64(encode_with_secret({ id = user.id , stream_id = stream_id })),
      redirect_uri = M.redirect_uri,
      client_id = config.networks[M.name].client_id,
      scope = 'channel:details:self channel:streamKey:self channel:update:self chat:bypass_links chat:chat chat:connect recording:manage:self user:details:self'
    })
end

function M.register_oauth(params)
  local user, err = decode_with_secret(decode_base64(params.state))

  if not user then
    return false, nil, 'Beam error: no user info sent'
  end

  if not params.code then
    return false, nil, 'Beam error: no temporary access code'
  end

  local httpc = http.new()

  local res, err = httpc:request_uri('https://beam.pro/api/v1/oauth/token', {
    headers = {
      ['Content-Type'] = 'application/x-www-form-urlencoded',
    },
    method = 'POST',
    body = encode_query_string({
      grant_type = 'authorization_code',
      code = params.code,
      client_secret = config.networks[M.name].client_secret,
      client_id = config.networks[M.name].client_id,
      redirect_uri = M.redirect_uri,
    })
  })

  if res and type(res.status) ~= 'number' then
    res.status = tonumber(res.status:find('^%d+'))
  end

  if err or res.status >= 400 then
    return false, nil, err or res.body
  end

  local creds = from_json(res.body)

  local res, err = httpc:request_uri('https://beam.pro/api/v1/users/current', {
    headers = {
      ['Authorization'] = 'Bearer ' .. creds.access_token
    }
  })

  if res and type(res.status) ~= 'number' then
    res.status = tonumber(res.status:find('^%d+'))
  end

  if err or res.status >= 400 then
    return false, nil, err or res.body
  end

  local user_info = from_json(res.body)

  local res, err = httpc:request_uri(api_url .. '/channels/' .. user_info.channel.id .. '/details' , {
    method = 'GET',
    headers = {
      ['Authorization'] = 'Bearer ' .. creds.access_token,
      ['Content-Type'] = 'application/json',
    },
  })

  if res and type(res.status) ~= 'number' then
    res.status = tonumber(res.status:find('^%d+'))
  end

  if err or res.status >= 400 then
    return false, nil, err or res.body
  end

  local channel_info = from_json(res.body)

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
  for i,v in pairs(form) do
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

  local account = account:get_all()
  local stream = stream:get_all()

  local fields = M.metadata_fields()
  for i,f in ipairs(fields) do
    if f.required == true then
      if not stream[f] or len(stream[f]) == 0 then
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
  local httpc = http.new()

  local res, err = httpc:request_uri(api_url .. '/types?' .. encode_query_string({
    query = game,
    limit = 1,
  }), {
    headers = {
      ['Authorization'] = 'Bearer ' .. access_token,
      ['Content-Type'] = 'application/json',
    },
  })

  if err or res.status >= 400 then
    return false, err or res.body
  end

  local games = from_json(res.body)

  local res, err = httpc:request_uri(api_url .. '/channels/' .. channel_id , {
    method = 'PATCH',
    headers = {
      ['Authorization'] = 'Bearer ' .. access_token,
      ['Content-Type'] = 'application/json',
    },
    body = to_json({
      name = title,
      audience = audience,
      typeId = games[1].id,
    })
  })

  if err or res.status >= 400 then
    return false, err or res.body
  end

  local channel_info = from_json(res.body)

  local http_url = 'https://beam.pro/' .. channel_info.token
  stream_o:set('http_url',http_url)
  stream_o:set('channel_id',account['channel_id'])

  return rtmp_url, nil

end

function M.publish_stop(account, stream)
  return true, nil
end

function M.check_errors(account)
  local access_token, exp = account:get('access_token')
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

function M.notify_update(account, stream)
  return true
end

function M.create_comment_funcs(account, stream, send)
  local read_func = nil
  local refresh_token = account['refresh_token']

  local access_token, expires_in, refresh_token, expires_at = refresh_access_token_wrapper(account)

  local httpc = http.new()
  local res, err = httpc:request_uri(api_url .. '/chats/' .. stream['channel_id'],
  {
    method = 'GET',
    headers = {
      ['Authorization'] = 'Bearer ' .. access_token,
      ['Content-Type'] = 'application/json',
    },
  })

  if err or res.status >= 400 then
    return false, err or res.body
  end
  local chat_endpoints = from_json(res.body)

  local ws = ws_client:new()
  local ok, err = ws:connect(chat_endpoints.endpoints[1])

  if not ok then
    ngx_log(ngx.ERR,'[Beam] Unable to connect to websocket: ' .. err)
  end

  local data, typ, err = ws:recv_frame()
  if not data then
    return nil, nil
  end
  local resp = from_json(data)

  if resp.type ~= 'event' or resp.event ~= 'WelcomeEvent' then
    return nil,nil
  end

  local auth = to_json({
    type = 'method',
    method = 'auth',
    arguments = { tonumber(stream['channel_id']), tonumber(account['user_id']), chat_endpoints['authkey'] },
    id = 0,
  })

  ws:send_text(auth)

  local data, typ, err = ws:recv_frame()
  if not data then
    return nil, nil
  end
  local resp = from_json(data)

  if resp.error ~= cjson.null then
    return nil, nil
  end

  if send then
    read_func = function()
      while true do
        local data, typ, err = ws:recv_frame()
        if typ == 'text' then
          local msg = from_json(data)
          if msg.type == 'event' and msg.event == 'ChatMessage' then
            local send_msg = false
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
                },
                text = txt,
                markdown = txt:escape_markdown(),
              })
            end
          end
        end
      end
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


  return read_func, write_func
end

function M.create_viewcount_func(account, stream, send)
  local refresh_token = account['refresh_token']

  local access_token, expires_in, refresh_token, expires_at = refresh_access_token_wrapper(account)

  if not send then
    return nil
  end

  return function()
    while true do
      access_token, expires_in, refresh_token, expires_at = refresh_access_token(refresh_token, access_token, expires_in, expires_at)
      if access_token then
        local httpc = http.new()
        local res, err = httpc:request_uri(api_url .. '/channels/' .. account['channel_id'] , {
          method = 'GET',
          headers = {
            ['Authorization'] = 'Bearer ' .. access_token,
            ['Content-Type'] = 'application/json',
          },
        })

        if err or res.status >= 400 then
          return false, err
        end

        local channel_info = from_json(res.body)
        send({viewer_count = channel_info.viewersCurrent})
      end
      ngx.sleep(60)
    end
  end
end

return M

