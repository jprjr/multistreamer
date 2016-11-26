local lapis = require'lapis'
local app = lapis.Application()
local config = require('lapis.config').get()
local db = require'lapis.db'

local User = require'models.user'
local Account = require'models.account'
local Stream = require'models.stream'
local StreamAccount = require'models.stream_account'
local SharedAccount = require'models.shared_account'

local respond_to = lapis.application.respond_to
local encode_with_secret = lapis.application.encode_with_secret
local decode_with_secret = lapis.application.decode_with_secret

local tonumber = tonumber
local length = string.len
local insert = table.insert
local sort = table.sort

app:enable('etlua')
app.layout = require'views.layout'

app:before_filter(function(self)
  self.networks = networks
  self.user = User:read_session(self)
  if self.session.status_msg then
    self.status_msg = self.session.status_msg
    self.session.status_msg = nil
  end
end)

local function err_out(req, err)
  req.session.status_msg = { type = 'error', msg = err }
  return req:write({ redirect_to = req:url_for('site-root') })
end

local function plain_err_out(req,err,status)
  local status = status
  if not status then
    status = 404
  end
  return req:write({
    layout = 'plain',
    content_type = 'text/plain',
    status = status
  }, err)
end

local function require_login(self)
  if not self.user then
    return false, 'not logged in'
  end
  return true, nil
end

local function get_all_streams_accounts(uuid)
  if not uuid then
    return false, 'UUID not provided'
  end
  local stream = Stream:find({ uuid = uuid })
  if not stream then
    return false, 'Stream not found'
  end
  local sas = stream:get_streams_accounts()
  local ret = {}
  for _,sa in pairs(sas) do
    local account = sa:get_account()
    account.network = networks[account.network]
    insert(ret, { account, sa } )
  end
  return ret, nil
end

app:match('login', config.http_prefix .. '/login', respond_to({
  GET = function(self)
    return { render = 'login' }
  end,
  POST = function(self)
    local user = User:login(self.params.username, self.params.password)
    if(user) then
      user:write_session(self)
      return { redirect_to = self:url_for('site-root') }
    else
      return { render = 'login' }
    end
  end,
}))

app:match('logout', config.http_prefix .. '/logout', function(self)
  User:unwrite_session(self)
  return { redirect_to = self:url_for('site-root') }
end)

app:match('stream-edit', config.http_prefix .. '/stream(/:id)', respond_to({
  before = function(self)
    if not require_login(self) then return err_out(self,'login required') end

    if self.params.id then
      self.stream = Stream:find({ id = self.params.id })
      local ok, err = self.stream:check_user(self.user)
      if err then return err_out(self, err) end
    end

    self.accounts = {}
    local acc = self.user:get_accounts()
    if not acc then acc = {} end
    for _,account in pairs(acc) do
      account.network = networks[account.network]
      insert(self.accounts,account)
    end

    local sas = self.user:get_shared_accounts()
    for _,sa in pairs(sas) do
      local account = sa:get_account()
      account.shared = true
      account.network = networks[account.network]
      insert(self.accounts,account)
    end
    sort(self.accounts, function(a,b)
      return a.network.displayname < b.network.displayname
    end)
  end,
  GET = function(self)
    return { render = 'stream' }
  end,
  POST = function(self)
    self.params.accounts = {}

    for _,account in pairs(self.accounts) do
      if self.params['account.'..account.id] and self.params['account.'..account.id] == 'on' then
        self.params.accounts[account.id] = true
      else
        self.params.accounts[account.id] = false
      end
    end

    self.stream, err = Stream:save_stream(self.user,self.stream,self.params)
    if err then return err_out(self, err) end

    self.session.status_msg = { type = 'success', msg = 'Stream updated' }
    return { redirect_to = self:url_for('metadata-edit')..self.stream.id }
  end,
}))

app:match('metadata-dummy', config.http_prefix .. '/metadata', function(self)
  return { redirect_to = self:url_for('site-root') }
end)

app:match('metadata-edit', config.http_prefix .. '/metadata/:id', respond_to({
  before = function(self)
    if not require_login(self) then return err_out(self,'login required') end
    self.stream = Stream:find({ id = self.params.id })
    if not (self.stream) or not (self.stream:check_user(self.user)) then
      return err_out(self,'stream not found')
    end
    self.accounts = self.stream:get_accounts()
    for _,acc in pairs(self.accounts) do
      acc.network = networks[acc.network]
    end
    sort(self.accounts, function(a,b)
      if not a then return false end
      if not b then return false end
      return a.network.displayname < b.network.displayname
    end)
    self.public_rtmp_url = config.public_rtmp_url
    if not config.rtmp_prefix or length(config.rtmp_prefix) == 0 then
      self.rtmp_prefix = 'multistreamer'
    else
      self.rtmp_prefix = config.rtmp_prefix
    end
  end,
  GET = function(self)
    return { render = 'metadata' }
  end,
  POST = function(self)
    if self.params.title then
      self.stream:set('title',self.params.title)
    end
    if self.params.description then
      self.stream:set('description',self.params.description)
    end
    for _,account in pairs(self.accounts) do
      local metadata_fields = account.network.metadata_fields()
      if not metadata_fields then metadata_fields = {} end
      for i,field in pairs(metadata_fields) do
        local v = self.params[field.key .. '.' .. account.id]
        if field.required and not v then
          return err_out(self,'Field "' .. field.label ..'" required for account type '.. account.network.displayname)
        elseif v then
          self.stream:get_stream_account(account):set(field.key,v)
        else
          self.stream:get_stream_account(account):unset(field.key)
        end
      end
    end

    self.session.status_msg = { type = 'success', msg = 'Settings saved' }
    return { redirect_to = self:url_for('metadata-edit') .. self.stream.id }
  end,
}))

app:match('publish-start',config.http_prefix .. '/on-publish', respond_to({
  GET = function(self)
    return plain_err_out(self,'Not Found')
  end,
  POST = function(self)
    local sas, err = get_all_streams_accounts(self.params.name)
    if not sas then
      return plain_err_out(self,err)
    end
    for _,v in pairs(sas) do
      local account = v[1]
      local sa = v[2]
      local rtmp_url, err = account.network.publish_start(account:get_keystore(),sa:get_keystore())
      if (not rtmp_url) or err then
        return plain_err_out(self,'Unable to start stream ('.. account.name ..'): ' .. err)
      end
      sa:update({rtmp_url = rtmp_url})
    end
    return plain_err_out(self,'OK',200)
 end,
}))

app:match('on-update',config.http_prefix .. '/on-update', respond_to({
  GET = function(self)
    return plain_err_out(self,'Not Found')
  end,
  POST = function(self)
    local sas, err = get_all_streams_accounts(self.params.name)
    if not sas then
      return plain_err_out(self,err)
    end
    for _,v in pairs(sas) do
      local account = v[1]
      local sa = v[2]
      local ok, err = account.network.notify_update(account:get_keystore(),sa:get_keystore())
      if not ok then
        return plain_err_out(self,'Unable to start stream ('.. account.name ..'): ' .. err)
      end
    end
    return plain_err_out(self,'OK',200)
 end,
}))

app:post('publish-stop',config.http_prefix .. '/on-done',function(self)
  local sas, err = get_all_streams_accounts(self.params.name)
  if not sas then
    return plain_err_out(self,err)
  end
  for _,v in pairs(sas) do
    local account = v[1]
    local sa = v[2]
    account.network.publish_stop(account:get_keystore(),sa:get_keystore())
    sa:update({rtmp_url = db.NULL})
  end
  return plain_err_out(self,'OK',200)
end)

app:get('site-root', config.http_prefix .. '/', function(self)
  if not require_login(self) then
    return { redirect_to = 'login' }
  end

  self.accounts = self.user:get_accounts()
  self.streams = self.user:get_streams()
  if not self.accounts then self.accounts = {} end
  if not self.streams then self.streams = {} end

  local sas = self.user:get_shared_accounts()
  for _,sa in pairs(sas) do
    local account = sa:get_account()
    account.shared = true
    insert(self.accounts,account)
  end
  for k,v in pairs(self.accounts) do
    if networks[v.network] then
      v.network = networks[v.network]
      v.errors = v.network.check_errors(v:get_keystore())
    end
  end

  sort(self.accounts,function(a,b)
    if not a.network.displayname then
      return false
    elseif not b.network.displayname then
      return true
    end
    return a.network.displayname < b.network.displayname
  end)

  sort(self.streams,function(a,b)
    return a.name < b.name
  end)

  return { render = 'index' }
end)

app:match('account-delete', config.http_prefix .. '/account/:id/delete', respond_to({
  before = function(self)
    if not require_login(self) then
      return { redirect_to = 'login' }
    end
    local account = Account:find({ id = self.params.id })
    if not account or not account:check_user(self.user) then
      return err_out(self,'Not authorized to modify that account')
    end
    if not account:check_owner(self.user) then
      account.shared = true
    end
    self.account = account
    self.account.network = networks[self.account.network]
  end,
  GET = function(self)
    return { render = "account-delete" }
  end,
  POST = function(self)
    local sas = self.account:get_streams_accounts()
    for _,sa in pairs(sas) do
      if self.account.shared then
        if sa:get_stream():get_user().id == self.user.id then
          sa:get_keystore():unset_all()
          sa:delete()
        end
      else
        sa:get_keystore():unset_all()
        sa:delete()
      end
    end

    if self.account.shared then
      local sa = SharedAccount:find({
        account_id = self.account.id,
        user_id = self.user.id,
      })
      sa:delete()
      self.session.status_msg = { type = 'success', msg = 'Account removed' }
    else
      local sas = self.account:get_shared_accounts()
      if not sas then sas = {} end
      for _,sa in pairs(sas) do
        sa:delete()
      end
      self.account:get_keystore():unset_all()
      self.account:delete()
      self.session.status_msg = { type = 'success', msg = 'Account deleted' }
    end
    return { redirect_to = self:url_for('site-root') }
  end,
}))

app:match('account-share', config.http_prefix .. '/account/:id/share', respond_to({
  before = function(self)
    if not require_login(self) then
      return { redirect_to = 'login' }
    end
    local account = Account:find({ id = self.params.id })
    if not account or not account:check_owner(self.user) or not networks[account.network].allow_sharing then
      return err_out(self,'Not authorized to share that account')
    end
    self.account = account
    self.account.network = networks[self.account.network]
    self.users = User:select('where id != ?',self.user.id)
    for i,other_user in pairs(self.users) do
      local sa = SharedAccount:find({ account_id = self.account.id, user_id = other_user.id})
      if not sa then
        self.users[i].shared = false
      else
        self.users[i].shared = true
      end
    end
  end,
  GET = function(self)
    return { render = 'account-share' }
  end,
  POST = function(self)
    for _,other_user in pairs(self.users) do
      if self.params['user.'..other_user.id] and self.params['user.'..other_user.id] == 'on' then
        self.account:share(other_user.id)
      else
        self.account:unshare(other_user.id)
      end
    end
    self.session.status_msg = { type = 'success', msg = 'Sharing settings updated' }
    return { redirect_to = self:url_for('account-share', { id = self.account.id }) }

  end,
}))


for t,m in networks() do
  if m.register_oauth then
    app:match('auth-'..m.name, config.http_prefix .. '/auth/' .. m.name, respond_to({
      GET = function(self)
        local account, err = m.register_oauth(self.params)
        if err then return err_out(self,err) end

        self.session.status_msg = { type = 'success', msg = 'Account saved' }
        return { redirect_to = self:url_for('site-root') }
      end,
    }))
  elseif m.create_form then
    app:match('account-'..m.name, config.http_prefix .. '/account/' .. m.name .. '(/:id)', respond_to({
      before = function(self)
        self.network = m
        if self.params.id then
          self.account = Account:find({ id = self.params.id })
          local ok, err = self.account:check_owner(self.user)
          if not ok then return err_out(self,err) end
          ok, err = self.account:check_network(self.network)
          if not ok then return err_out(self,err) end
        end
      end,
      GET = function(self)
        return { render = 'account' }
      end,
      POST = function(self)
        local account, err = m.save_account(self.user, self.account, self.params)
        if err then return err_out(self, err) end
        self.session.status_msg = { type = 'success', msg = 'Account saved' }
        return { redirect_to = self:url_for('site-root') }
      end,
    }))
  end
end

return app
