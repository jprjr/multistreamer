local Model = require('lapis.db.model').Model
local config = require'multistreamer.config'
local http = require'resty.http'
local encode_base64 = ngx.encode_base64
local decode_base64 = ngx.decode_base64
local hmac_sha1 = ngx.hmac_sha1
local resty_random = require'resty.random'
local resty_md5 = require "resty.md5"
local str = require'resty.string'

local ngx_log = ngx.log
local ngx_err = ngx.ERR
local ngx_debug = ngx.DEBUG

local function make_token()
    local rand = resty_random.bytes(16,true)
    while rand == nil do
      rand = resty_random.bytes(16,true)
    end
    local md5 = resty_md5:new()
    md5:update(rand)
    local digest = md5:final()
    return str.to_hex(digest):upper():sub(1,20)
end

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
  reset_token = function(self)
    self:update({access_token = make_token()})
  end
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
      user = self:create({username = username:lower(), access_token = make_token() })
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
  if res.params.token then
    return self:find({ access_token = res.params.token })
  end
  return nil
end

function User:unwrite_session(res)
  res.session.user = nil
end

function User:read_auth(self)
  local auth = self.req.headers['authorization']
  if not auth then
    return nil
  end

  local userpassword = decode_base64(auth:match("Basic%s+(.*)"))
  if not userpassword then return nil end
  local username, password = userpassword:match("([^:]*):(.*)")
  return User:login(username,password)
end

function User:read_bearer(self)
  local auth = self.req.headers['authorization']
  if not auth then
    return nil
  end

  local bearertoken = auth:match("Bearer%s(.*)")
  if not bearertoken then return nil end
  return User:find({ access_token = bearertoken })
end

return User;

