local Model = require('lapis.db.model').Model
local config = require'multistreamer.config'
local http = require'resty.http'
local encode_base64 = ngx.encode_base64
local hmac_sha1 = ngx.hmac_sha1

local ngx_log = ngx.log
local ngx_err = ngx.ERR
local ngx_debug = ngx.DEBUG

local User = Model:extend('users', {
  timestamp = true,
  relations = {
    { 'accounts', has_many = 'Account' },
    { 'streams', has_many = 'Stream' },
    { 'shared_accounts', has_many = 'SharedAccount' },
    { 'shared_streams', has_many = 'SharedStream' },
  },
  write_session = function(self, res)
    res.session.user = {
      username = self.username,
      key = encode_base64(hmac_sha1(config.secret,self.username))
    }
  end,
})

function User:login(username,password)
  local error = nil
  local user = nil

  ngx_log(ngx_debug, 'checking if username is valid with auth_endpoint');

  local httpc = http.new()
  local res, err = httpc:request_uri(config.auth_endpoint, {
    method = "GET",
    headers = {
      ["Authorization"] = "Basic " .. encode_base64(username .. ':' .. password)
    }
  })
  if not res then
    ngx_log(ngx_err, 'User: login - connection failed: ' .. err)
    error = err
  elseif(res.status >= 200 and res.status < 300) then
    ngx_log(ngx_debug, 'login succeeded');
    user = self:find({ username = username:lower() })
    if not user then
      user = self:create({username = username:lower() })
    end
  else
    ngx_log(ngx_debug, 'login failed');
  end

  return user, error
end

function User:read_session(res)
  if res.session and res.session.user then
    local u_session = res.session.user
    if(encode_base64(hmac_sha1(config.secret,u_session.username)) == u_session.key) then
      return self:find({ username = u_session.username })
    end
  end
  return nil
end

function User:unwrite_session(res)
  res.session.user = nil
end

return User;

