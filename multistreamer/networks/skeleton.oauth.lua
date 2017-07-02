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

local http = require'resty.http'
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'

local M = {}

M.displayname = 'Skeleton OAuth Module'
M.allow_sharing = false

function M.get_oauth_url(user, stream_id)
  return 'http://example.com?' ..
    encode_query_string({
      state = encode_base64(encode_with_secret({ id = user.id, stream_id = stream.id })),
      redirect_uri = M.redirect_uri,
      client_id = config.networks[M.name].client_id,
      scope = 'some,scopes,that,you,need',
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

  -- first exchange the 'code' for a short-lived access token
  local res, err = httpc:request_uri('http://example.com/token?' ..
    encode_query_string({
      client_id = config.networks[M.name].client_id,
      redirect_uri = M.redirect_uri,
      client_secret = confign.networks[M.name].client_secret,
      code = params.code,
    }))

  if err or res.status >= 400 then
    return false, err
  end

  local creds = from_json(res.body)

  -- make some http request to get a userid
  local res, err = httpc:request_uri('http://example.com/info?' ..
    encode_query_string({
      access_token = creds.access_token,
    }))

  if err or res.status >= 400 then
    return false, err
  end

  local user_info = from_json(res.body)

  local sha1 = resty_sha1:new()
  sha1:update(user_info.id)
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
      name = user_info.name,
    })
  end

  account:set('access_token',creds.access_token)

  if account.user_id ~= user.id then
    return false, nil, "Account already registered"
  end

  local sa = nil
  if users.stream_id then
    sa = StreamAccount:find({ account_id = account.id, stream_id = user.stream_id })
    if not sa then
      sa = StreamAccount:create({ account_id = account.id, stream_id = user.stream_id })
    end
  end

  return account, sa, nil

end

function M.metadata_form(account, stream)
  local form = M.metadata_fields()

  -- add in some default values etc to the form
  return form

end

function M.metadata_fields()
  return {
    [1] = {
      type = 'text',
      label = 'Field 1',
      key = 'field1',
      required = true,
    },
    [2] = {
      type = 'text',
      label = 'Field 2',
      key = 'field2',
      required = true,
    },
  }

end

function M.publish_start(account, stream)
  local access_token = account:get('access_token')
  local param1 = stream:get('field1')
  local param2 = stream:get('field2')

  local res, err = httpc:request_uri('http://example.com/update', {
    method = 'POST',
    headers = {
      ['Access'] = 'OAuth ' .. access_token,
    },
    body = to_json({param1 = param1, param2 = param2}),
  })

  if err or res.status >= 400 then
    return false, err or res.body
  end

  local http_url = somehow_get_http_url()
  local rtmp_url = from_json(res.body).rtmp_url
  stream:set('http_url',http_url)

  return rtmp_url, nil

end

function M.publish_stop(account, stream)
  local access_token = account:get('access_token')
  local param1 = stream:get('field1')
  local param2 = stream:get('field2')

  stream:unset('http_url')

  local res, err = httpc:request_uri('http://example.com/stop', {
    method = 'POST',
    headers = {
      ['Access'] = 'OAuth ' .. access_token,
    },
    body = to_json({param1 = param1, param2 = param2}),
  })
  return true
end

function M.check_errors(account)
  return false,nil
end

function M.notify_update(account, stream)
  return true
end

function M.create_comment_funcs(account, stream, send)
  return nil,nil
end

function M.create_viewcount_func(account, stream, send)
  return nil,nil
end

return M
