local lapis = require'lapis'
local app = lapis.Application()
local config = require'multistreamer.config'
local db = require'lapis.db'

local redis = require'multistreamer.redis'
local publish = redis.publish
local subscribe = redis.subscribe
local endpoint = redis.endpoint

local User = require'models.user'
local Account = require'models.account'
local Stream = require'models.stream'
local StreamAccount = require'models.stream_account'
local SharedAccount = require'models.shared_account'
local SharedStream  = require'models.shared_stream'
local Webhook = require'models.webhook'

local respond_to = lapis.application.respond_to
local encode_with_secret = lapis.application.encode_with_secret
local decode_with_secret = lapis.application.decode_with_secret
local to_json   = require('lapis.util').to_json
local from_json = require('lapis.util').from_json

local WebsocketServer = require'multistreamer.websocket.server'

local tonumber = tonumber
local pairs = pairs
local len = string.len
local lower = string.lower
local insert = table.insert
local sort = table.sort
local streams_dict = ngx.shared.streams
local status_dict = ngx.shared.status
local capture = ngx.location.capture

local pid = ngx.worker.pid()

app:enable('etlua')
app.layout = require'views.layout'

app:before_filter(function(self)
  self.networks = networks
  self.user = User:read_session(self)
  if self.session.status_msg then
    self.status_msg = self.session.status_msg
    self.session.status_msg = nil
  end
  if status_dict:get('processmgr_error') or status_dict:get('chatmgr_error') then
    self.status_msg = {
      type = 'error',
      msg = 'Unrecoverable error! Please check logs and restart Multistreamer',
    }
  end
  self.public_http_url = config.public_http_url
  self.http_prefix = config.http_prefix
  self.public_irc_hostname = config.public_irc_hostname
  self.public_irc_port = config.public_irc_port
  self.public_irc_ssl = config.public_irc_ssl
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
    return false,false, 'UUID not provided'
  end
  local stream = Stream:find({ uuid = uuid })
  if not stream then
    return false,false, 'Stream not found'
  end
  local sas = stream:get_streams_accounts()
  local ret = {}
  for _,sa in pairs(sas) do
    local account = sa:get_account()
    account.network = networks[account.network]
    insert(ret, { account, sa } )
  end
  return stream, ret, nil
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
      self.metadata_level = self.stream:check_meta(self.user)
      self.chat_level = self.stream:check_chat(self.user)

      self.stream_status = streams_dict:get(self.stream.id)
      if self.stream_status then
        self.stream_status = from_json(self.stream_status)
      else
        self.stream_status = {
            data_incoming = false,
            data_pushing = false,
            data_pulling = false,
        }
      end

      if self.metadata_level < 1 and self.chat_level < 1 then
        return err_out(self,'Stream not found')
      end
    end

    local valid_subsets = {
      general = true,
      dashboard = true,
      accounts = true,
      permissions = true,
      advanced = true,
      webhooks = true,
    }

    if not self.stream then
      self.params.subset = 'general'
    elseif not self.params.subset then
      self.params.subset = 'dashboard'
    end

    if not self.params.tab then
      self.params.tab = self.params.subset
    end

    if not valid_subsets[self.params.subset] then
      self.params.subset = 'general'
    end

    if not valid_subsets[self.params.tab] then
      self.params.tab = 'general'
    end

    self.users = User:select('where id != ?',self.user.id)
    for i,other_user in pairs(self.users) do
      local ss = nil
      if self.stream then
        ss = SharedStream:find({ stream_id = self.stream.id, user_id = other_user.id})
      end
      if not ss then
        self.users[i].chat_level = 0
        self.users[i].metadata_level = 0
      else
        self.users[i].chat_level = ss.chat_level
        self.users[i].metadata_level = ss.metadata_level
      end
    end

    self.webhooks = self.stream and self.stream:get_webhooks() or {}
    self.webhook_types = Webhook.types
    self.webhook_events = Webhook.events

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
      local u = account:get_user()
      account.shared = true
      account.shared_from = u.username
      account.network = networks[account.network]
      insert(self.accounts,account)
    end
    sort(self.accounts, function(a,b)
      return a.network.displayname < b.network.displayname
    end)
    self.public_rtmp_url = config.public_rtmp_url
    self.rtmp_prefix = config.rtmp_prefix
  end,
  GET = function(self)
    if not self.params.subset or self.params.subset == 'general' then
      return { render = 'stream' }
    elseif self.params.subset == 'accounts' then
      return { render = 'stream-accounts' }
    elseif self.params.subset == 'dashboard' then
      return { render = 'stream-dashboard' }
    elseif self.params.subset == 'permissions' then
      return { render = 'stream-permissions' }
    elseif self.params.subset == 'advanced' then
      return { render = 'stream-advanced' }
    elseif self.params.subset == 'webhooks' then
      return { render = 'stream-webhooks' }
    end
  end,
  POST = function(self)

    local update_published = false

    if self.params.subset == 'general' then
      self.stream, err = Stream:save_stream(self.user,self.stream,self.params)
      if err then return err_out(self, err) end
    end

    if self.params.subset == 'accounts' then
      local accounts = {}
      for _,account in pairs(self.accounts) do
        if self.params['account.'..account.id] and self.params['account.'..account.id] == 'on' then
          accounts[account.id] = true
        else
          accounts[account.id] = false
        end
      end
      Stream:save_accounts(self.user, self.stream, accounts)
    end

    if self.params.subset == 'advanced' then
      if not self.params.ffmpeg_pull_args or len(self.params.ffmpeg_pull_args) == 0 then
        self.stream:update({ffmpeg_pull_args = db.NULL})
      else
        self.stream:update({ffmpeg_pull_args = self.params.ffmpeg_pull_args})
      end
    end

    if self.params.subset == 'permissions' then
      for _,other_user in pairs(self.users) do
        local chat_level = 0
        local metadata_level = 0
        if self.params['user.'..other_user.id..'.chat'] then
          chat_level = tonumber(self.params['user.'..other_user.id..'.chat'])
        end
        if self.params['user.'..other_user.id..'.metadata'] then
          metadata_level = tonumber(self.params['user.'..other_user.id..'.metadata'])
        end
        local ss = SharedStream:find({ stream_id = self.stream.id, user_id = other_user.id })
        if ss then
          ss:update({chat_level = chat_level, metadata_level = metadata_level})
        else
          SharedStream:create({
            stream_id = self.stream.id,
            user_id = other_user.id,
            chat_level = chat_level,
            metadata_level = metadata_level,
          })
        end
      end
    end

    if self.params.subset == 'webhooks' then
      if self.params['webhook.0.url'] and len(self.params['webhook.0.url']) > 0 and self.params['webhook.0.type'] and tonumber(self.params['webhook.0.type']) > 0 then
        local p = {}
        p.stream_id = self.stream.id
        p.url = self.params['webhook.0.url']
        p.type = self.params['webhook.0.type']
        p.notes = self.params['webhook.0.notes']
        p.events = {}
        for _,v in ipairs(self.webhook_events) do
          if self.params['webhook.0.event.' .. v.value] and
             self.params['webhook.0.event.' .. v.value] == 'on' then
            p.events[v.value] = true
          else
            p.events[v.value] = false
          end
        end
        local webhook = Webhook:create(p)
      end

      for i,v in ipairs(self.webhooks) do
        if len(self.params['webhook.' .. v.id .. '.url']) <= 0 then
          v:delete()
        else
          v.notes = self.params['webhook.'..v.id..'.notes']
          v.type = self.params['webhook.' .. v.id .. '.type']
          for _,e in ipairs(self.webhook_events) do
            if self.params['webhook.' .. v.id .. '.event.' .. e.value] and
               self.params['webhook.' .. v.id .. '.event.' .. e.value] == 'on' then
              v:enable_event(e.value)
            else
              v:disable_event(e.value)
            end
          end
          v:save()
        end
      end
    end

    if self.params.subset == 'dashboard' then
      if self.metadata_level < 2 then
        return err_out(self,'Nice try buddy')
      end

      if self.params.title then
        self.stream:set('title',self.params.title)
      end
      if self.params.description then
        self.stream:set('description',self.params.description)
      end

      for _,account in pairs(self.accounts) do
        local sa = self.stream:get_stream_account(account)
        if sa then
          local ffmpeg_args = self.params['ffmpeg_args' .. '.' .. account.id]
          if ffmpeg_args and len(ffmpeg_args) > 0 then
              sa:update({ffmpeg_args = ffmpeg_args })
          else
              sa:update({ffmpeg_args = db.NULL })
          end

          local metadata_fields = account.network.metadata_fields()
          if not metadata_fields then metadata_fields = {} end
          for i,field in pairs(metadata_fields) do
            local v = self.params[field.key .. '.' .. account.id]
            if v and len(v) > 0 then
              sa:set(field.key,v)
            else
              sa:unset(field.key)
            end
          end
        end
      end

      publish('stream:update',self.stream)
      update_published = true

      if self.params['customPullBtn'] ~= nil then
        self.stream_status.data_pulling = true
        streams_dict:set(self.stream.id, to_json(self.stream_status))
        publish('process:start:pull', {
          worker = pid,
          id = self.stream.id,
        })
        self.session.status_msg = { type = 'success', msg = 'Custom Puller Started' }
        return { redirect_to = self:url_for('stream-edit') .. self.stream.id .. '?subset=dashboard' }
      end

      if self.params['customPullBtnStop'] ~= nil then
        self.stream_status.data_pulling = false
        streams_dict:set(self.stream.id, to_json(self.stream_status))
        publish('process:end:pull', {
          id = self.stream.id,
        })
        self.session.status_msg = { type = 'success', msg = 'Custom Puller Stopped' }
        return { redirect_to = self:url_for('stream-edit') .. self.stream.id .. '?subset=dashboard' }
      end
      local success_msg = 'Settings saved'

      -- is there incoming data, and the user clicked the golivebutton? start the stream
      if self.stream_status.data_incoming == true and self.stream_status.data_pushing == false and self.params['goLiveBtn'] ~= nil then
        success_msg = 'Stream started'
        self.stream_status.data_pushing = true
        local sas = {}

        for _,account in pairs(self.accounts) do
          local sa = StreamAccount:find({stream_id = self.stream.id, account_id = account.id})
          if sa then
            local rtmp_url, err = account.network.publish_start(account:get_keystore(),sa:get_keystore())
            if (not rtmp_url) or err then
              return err_out(self,err)
            end
            sa:update({rtmp_url = rtmp_url})
            insert(sas, sa)
          end
        end

        publish('process:start:push', {
          worker = pid,
          id = self.stream.id,
        })

        publish('stream:start', {
          worker = pid,
          id = self.stream.id,
          status = self.stream_status,
        })

        for _,v in pairs(self.stream:get_webhooks()) do
          v:fire_event('stream:start', sas)
        end
      end

      if self.stream_status.data_pushing == true and self.params['stopLiveBtn'] ~= nil then
        self.stream_status.data_pushing = false
        local account_ids = {}
        for _,account in pairs(self.accounts) do
          local sa = StreamAccount:find({ stream_id = self.stream.id, account_id = account.id })
          if sa then
            insert(account_ids,account.id)
          end
        end

        publish('stream:end', {
          id = self.stream.id,
        })

        publish('process:end:push', {
          id = self.stream.id,
          accounts = account_ids,
        })

        for _,v in pairs(self.stream:get_webhooks()) do
          v:fire_event('stream:end')
        end
      end

      streams_dict:set(self.stream.id, to_json(self.stream_status))
    end

    if update_published == false then
      publish('stream:update',self.stream)
    end

    self.session.status_msg = { type = 'success', msg = 'Stream updated' }
    return { redirect_to = self:url_for('stream-edit', { id = self.stream.id }) .. '?subset=' .. self.params.tab }
  end,
}))

app:match('profile-edit', config.http_prefix .. '/profile/:id', respond_to({
  before = function(self)
    if not require_login(self) then return err_out(self,'login required') end
  end,
  GET = function(self)
    return { render = 'profile' }
  end,
  POST = function(self)
    if self.params['resetTokenBtn'] ~= nil then
      self.user:reset_token()
    end
    return { render = 'profile' }
  end,
}))

app:match('metadata-dummy', config.http_prefix .. '/metadata', function(self)
  return { redirect_to = self:url_for('site-root') }
end)

app:match('metadata-edit', config.http_prefix .. '/metadata/:id', respond_to({
  GET = function(self)
    return { redirect_to = self:url_for('stream-edit', { id = self.params.id }) }
  end,
  POST = function(self)
    return { redirect_to = self:url_for('stream-edit', { id = self.params.id }) }
  end,
}))

app:match('publish-start',config.http_prefix .. '/on-publish', respond_to({
  GET = function(self)
    return plain_err_out(self,'Not Found')
  end,
  POST = function(self)
    local stream, sas, err = get_all_streams_accounts(self.params.name)
    if not stream then
      return plain_err_out(self,err)
    end

    local stream_status = streams_dict:get(stream.id)
    if stream_status then
      stream_status = from_json(stream_status)
    else
      stream_status = {
        data_incoming = false,
        data_pushing = false,
        data_pulling = false,
      }
    end

    stream_status.data_incoming = true
    streams_dict:set(stream.id, to_json(stream_status))

    if stream.preview_required == 0 and #sas > 0 then
      local hook_sas = {}
      for _,v in pairs(sas) do
        local account = v[1]
        local sa = v[2]
        local rtmp_url, err = account.network.publish_start(account:get_keystore(),sa:get_keystore())
        if (not rtmp_url) or err then
          return plain_err_out(self,err)
        end
        sa:update({rtmp_url = rtmp_url})
        insert(hook_sas, sa)
      end

      stream_status.data_pushing = true
      streams_dict:set(stream.id, to_json(stream_status))

      publish('process:start:push', {
        worker = pid,
        id = stream.id,
      })

      for _,v in pairs(stream:get_webhooks()) do
        v:fire_event('stream:start', hook_sas)
      end

    end

    publish('stream:start', {
      worker = pid,
      id = stream.id,
      status = stream_status,
    })

    return plain_err_out(self,'OK',200)
 end,
}))

app:match('on-update',config.http_prefix .. '/on-update', respond_to({

  GET = function(self)
    return plain_err_out(self,'Not Found')
  end,
  POST = function(self)
    if self.params.call == 'play' then
      return plain_err_out(self,'OK',200)
    end

    local stream, sas, err = get_all_streams_accounts(self.params.name)
    if not stream then
      return plain_err_out(self,err)
    end

    local stream_status = streams_dict:get(stream.id)
    if stream_status then
      stream_status = from_json(stream_status)
    else
      stream_status = {
        data_incoming = false,
        data_pushing = false,
        data_pulling = false,
      }
    end
    if stream_status.data_pushing == false then
      return plain_err_out(self,'OK',200)
    end

    for _,v in pairs(sas) do
      local account = v[1]
      local sa = v[2]
      local ok, err = account.network.notify_update(account:get_keystore(),sa:get_keystore())
      if err then
        return plain_err_out(self,err)
      end
    end

    return plain_err_out(self,'OK',200)
 end,
}))

app:post('publish-stop',config.http_prefix .. '/on-done',function(self)
  local stream, sas, err = get_all_streams_accounts(self.params.name)
  if not stream then
    return plain_err_out(self,err)
  end
  local stream_status = streams_dict:get(stream.id)
  if stream_status then
    stream_status = from_json(stream_status)
  else
    stream_status = {
      data_incoming = false,
      data_pushing = false,
      data_pulling = false,
    }
  end

  local accounts = {}
  for _,sa in pairs(sas) do
    insert(accounts,sa.account_id)
  end

  publish('stream:end', {
    id = stream.id,
  })

  if stream_status.data_pushing == true then
    for _,v in pairs(stream:get_webhooks()) do
      v:fire_event('stream:end')
    end
  end

  streams_dict:set(stream.id,nil)

  if stream_status.data_pushing == true then
    for _,v in pairs(sas) do
      local account = v[1]
      local sa = v[2]

      sa:update({rtmp_url = db.NULL})
      account.network.publish_stop(account:get_keystore(),sa:get_keystore())
    end
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
    local u = account:get_user()
    account.shared = true
    account.shared_from = u.username
    insert(self.accounts,account)
  end
  for k,v in pairs(self.accounts) do
    if networks[v.network] then
      v.network = networks[v.network]
      v.errors = v.network.check_errors(v:get_keystore())
    end
  end

  local sss = self.user:get_shared_streams()
  for _,ss in pairs(sss) do
    if ss.chat_level > 0 or ss.metadata_level > 0 then
      local stream = ss:get_stream()
      local u = stream:get_user()
      stream.shared = true
      stream.shared_from = u.username
      stream.chat_level = ss.chat_level
      stream.metadata_level = ss.metadata_level
      insert(self.streams,stream)
    end
  end

  for k,v in pairs(self.streams) do
    local stream_status = streams_dict:get(v.id)
    if stream_status then
      stream_status = from_json(stream_status)
    else
      stream_status = { data_pushing = false }
    end
    if stream_status.data_pushing == true then
      v.live = true
    else
      v.live = false
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
    if a.live ~= b.live then
      return a.live
    end
    return lower(a.name) < lower(b.name)
  end)

  return { render = 'index' }
end)

app:match('stream-delete', config.http_prefix .. '/stream/:id/delete', respond_to({
  before = function(self)
    local ok, err = require_login(self)
    if not ok then
      return err_out(self,err)
    end
    local stream = Stream:find({ id = self.params.id })
    if not stream then
      return err_out(self,'Not authorized to modify that stream')
    end
    local ok, err = stream:check_owner(self.user)
    if not ok then
      return err_out(self,'Not authorized to modify that stream')
    end

    self.stream = stream
  end,
  GET = function(self)
    return { render = 'stream-delete' }
  end,
  POST = function(self)
    self.stream.user = self.stream:get_user()
    local sas = self.stream:get_streams_accounts()
    for _,sa in pairs(sas) do
      sa:get_keystore():unset_all()
      sa:delete()
    end
    for _,ss in pairs(self.stream:get_stream_shares()) do
      ss:delete()
    end
    self.stream:get_keystore():unset_all()
    for _,wh in pairs(self.stream:get_webhooks()) do
      wh:delete()
    end
    publish('stream:delete',self.stream)
    self.stream:delete()
    self.session.status_msg = { type = 'success', msg = 'Stream removed' }
    return { redirect_to = self:url_for('site-root') }
  end
}))

app:match('stream-chat', config.http_prefix .. '/stream/:id/chat', respond_to({
  before = function(self)
    local ok, err = require_login(self)
    if not ok then
      return err_out(self,err)
    end

    local stream = Stream:find({ id = self.params.id })
    if not stream then
      return err_out(self, 'Not authorized to view this chat')
    end
    local level = stream:check_chat(self.user)
    if level == 0 then
      return err_out(self, 'Not authorized to view this chat')
    end
    self.stream = stream
  end,
  GET = function(self)
    return { layout = 'chatlayout', render = 'chat' }
  end,
}))

app:match('stream-video', config.http_prefix .. '/stream/:id/video(/*)', respond_to({
  before = function(self)
    local stream = Stream:find({ id = self.params.id })
    if not stream then
      return plain_err_out(self, 'Stream not found')
    end
    local ok = streams_dict:get(stream.id)
    if ok == nil or ok == 0 then
      return plain_err_out(self, 'Stream not live', 404)
    end
    self.stream = stream
  end,
  GET = function(self)
    local fn = self.params.splat
    if not fn then
      fn = 'index.m3u8'
    end

    local res = capture(config.http_prefix .. '/video_raw/' .. self.stream.uuid .. '/' .. fn)
    if res then
      if res.status == 302 then
        return plain_err_out(self, 'Stream not live', 404)
      end
      return self:write({
        layout = 'plain',
        content_type = res.header['content-type'],
        status = res.status,
      }, res.body)
    end
    return plain_err_out(self,'An error occured', 500)
  end,
}))

app:match('stream-ws', config.http_prefix .. '/ws/:id',respond_to({
  before = function(self)
    if not require_login(self) then
      return plain_err_out(self,'Not authorized', 403)
    end
    local stream = Stream:find({ id = self.params.id })
    if not stream then
      return plain_err_out(self,'Not authorized', 403)
    end
    local chat_level = stream:check_chat(self.user)
    if chat_level == 0 then
      return plain_err_out(self,'Not authorized', 403)
    end
    self.chat_level = chat_level
    self.stream = stream
  end,
  GET = function(self)
    local wb_server = WebsocketServer:new(self.user,self.stream,self.chat_level)
    wb_server:run()
  end,
}))


app:match('account-delete', config.http_prefix .. '/account/:id/delete', respond_to({
  before = function(self)
    local ok, err = require_login(self)
    if not ok then
      return err_out(self,err)
    end
    local account = Account:find({ id = self.params.id })
    if not account or not account:check_owner(self.user) then
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

app:match('stream-share',config.http_prefix .. '/stream/:id/share', respond_to({
  before = function(self)
    local ok, err = require_login(self)
    if not ok then
      return err_out(self,err)
    end
    local stream = Stream:find({ id = self.params.id })
    if not stream or not stream:check_owner(self.user) then
      return err_out(self,'Stream not found')
    end
    self.stream = stream
  end,
  GET = function(self)
    return { render = 'stream-share' }
  end,
  POST = function(self)
    self.session.status_msg = { type = 'success', msg = 'Sharing settings updated' }
    return { redirect_to = self:url_for('stream-share', { id = self.stream.id }) }
  end,
}))

app:match('account-share', config.http_prefix .. '/account/:id/share', respond_to({
  before = function(self)
    local ok, err = require_login(self)
    if not ok then
      return err_out(self,err)
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
        local account, sa, err = m.register_oauth(self.params)
        if err then return err_out(self,err) end

        self.session.status_msg = { type = 'success', msg = 'Account saved' }
        if sa then
          return { redirect_to = self:url_for('stream-edit', { id = sa.stream_id }) .. '?subset=accounts' }
        end
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
        local account, sa, err = m.save_account(self.user, self.account, self.params)
        if err then return err_out(self, err) end
        if self.params.ffmpeg_args and len(self.params.ffmpeg_args) > 0 then
          account:update({ ffmpeg_args = self.params.ffmpeg_args })
        else
          account:update({ ffmpeg_args = db.NULL })
        end
        self.session.status_msg = { type = 'success', msg = 'Account saved' }
        if sa then
          return { redirect_to = self:url_for('stream-edit', { id = sa.stream_id }) .. '?subset=accounts' }
        end
        return { redirect_to = self:url_for('site-root') }
      end,
    }))
  end
end

return app
