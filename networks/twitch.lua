local config = require('lapis.config').get()
local encode_query_string = require('lapis.util').encode_query_string
local encode_base64 = require('lapis.util.encoding').encode_base64
local decode_base64 = require('lapis.util.encoding').decode_base64
local encode_with_secret = require('lapis.util.encoding').encode_with_secret
local decode_with_secret = require('lapis.util.encoding').decode_with_secret
local to_json   = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local http = require'resty.http'
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'
local format = string.format
local insert = table.insert
local sort = table.sort

local Account = require'models.account'

local M = {}

M.displayname = 'Twitch'
M.allow_sharing = true

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
    if err then
      return false, err
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

  local endpoints = account:get('endpoints')
  if endpoints then
    endpoints = from_json(endpoints)
    for k,v in pairs(endpoints) do
      insert(form[3].options, {
        value = k,
        label = v.name
      })
    end
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
      insert(form[3].options, {
        value = k,
        label = v.name
      })
    end
    account:set('endpoints',to_json(endpoints), 10080)
  end

  sort(form[3].options,function(a,b)
    return a.label < b.label
  end)

  return form, nil
end

function M.publish_start(account, stream)
  local tclient = twitch_api_client(account:get('token'))

  local res, err = tclient:put('/channels/'..account:get('channel')..'/', {
    channel = {
      status = stream:get('title'),
      game = stream:get('game'),
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

  local endpoints = account:get('endpoints')
  if endpoints then
    endpoints = from_json(endpoints)
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
    account:set('endpoints',to_json(endpoints), 10080)
  end

  local endpoint = stream:get('endpoint')
  local stream_key = account:get('stream_key')

  local rtmp_url

  if endpoint and endpoints[endpoint] and stream_key then
    rtmp_url = endpoints[endpoint].url_template:gsub('{stream_key}',stream_key)
    return rtmp_url,nil
  end

  return false, 'unable to create rtmp url'

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
  local user, err = decode_with_secret(decode_base64(params.state))

  if not user then
    return false, 'error'
  end

  if not params.code then
    return false, 'error'
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
    })
  else
   -- this account might be owned by somebody else
    account:update({
      name = user_info.display_name,
    })
  end

  -- since we may have just taken somebody's account, we'll update
  -- the access token, channel etc anyway but return an error
  account:set('token',creds.access_token)
  account:set('channel',channel_info.name)
  account:set('stream_key',channel_info.stream_key)

  if(account.user_id ~= user.id) then
    return false, "Account already registered"
  end

  return account, nil
end

function M.check_errors(account)
  return false
end

return M
