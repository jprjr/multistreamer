-- luacheck: globals ngx networks
local ngx = ngx
local networks = networks

local lapis = require'lapis'
local app = lapis.Application()
local config = require'multistreamer.config'
local api_prefix = config.http_prefix .. '/api/v1'

local respond_to = require('lapis.application').respond_to
local to_json   = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local json_params = require('lapis.application').json_params
local cjson = require'cjson'
local db = require'lapis.db'

local redis = require'multistreamer.redis'
local publish = redis.publish

local User = require'models.user'
local Account = require'models.account'
local Stream = require'models.stream'
local StreamAccount = require'models.stream_account'
local SharedStream = require'models.shared_stream'
local SharedAccount = require'models.shared_account'
local Webhook = require'models.webhook'

local streams_dict = ngx.shared.streams
local pid = ngx.worker.pid()

local insert = table.insert
local pairs = pairs
local ipairs = ipairs

local function read_bearer(self)
  self.user = User.read_bearer(self)
  if not self.user then
    return self:write({ status = 401, json = { error = 'endpoint requires authorization' }})
  end
end

local function get_stream(self, id)
  if id then
    local stream = Stream:find({ id = id })
    if not stream then
      return { status = 400, json = { error = 'unauthorized to access that stream' } }
    end
    local chat_level, meta_level = stream:user_prep(self.user)
    local stream_status = streams_dict:get(stream.id)
    if stream_status then
      stream_status = from_json(stream_status)
    else
      stream_status = { data_pushing = false }
    end
    if stream_status.data_pushing == true then
      stream.live = true
    else
      stream.live = false
    end
    stream.webhooks = stream:get_webhooks()
    for _,w in pairs(stream.webhooks) do
      w.events = from_json(w.params).events
      w.params = nil
    end
    if chat_level > 0 or meta_level > 0 then

      return { json = { stream = stream } }
    end
    return { status = 400, json = { error = 'unauthorized to access that stream' } }
  end

  local streams = self.user:get_streams()
  for _,v in ipairs(streams) do
    v:user_prep(self.user)

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
    v.webhooks = v:get_webhooks()
    for _,w in pairs(v.webhooks) do
      w.events = from_json(w.params).events
      w.params = nil
    end
  end
  local sas = self.user:get_shared_streams()
  for _,v in ipairs(sas) do
    local s = v:get_stream()
    s:user_prep(self.user)

    local stream_status = streams_dict:get(s.id)
    if stream_status then
      stream_status = from_json(stream_status)
    else
      stream_status = { data_pushing = false }
    end
    if stream_status.data_pushing == true then
      s.live = true
    else
      s.live = false
    end
    s.webhooks = s:get_webhooks()
    for _,w in pairs(s.webhooks) do
      w.events = from_json(w.params).events
      w.params = nil
    end

    insert(streams,s)
  end
  return { json = { streams = streams } }
end

local function get_account(self, id)
  if id then
    local account = Account:find({ id = id })
    account:json_prep(self.user)
    if account:check_user(self.user) then
      return { json = { account = account } }
    end
    return { status = 400, json = { error = 'unauthorized to access that account' } }
  end
  local accounts = self.user:get_accounts()
  for _,v in ipairs(accounts) do
    v:json_prep(self.user)
  end
  local sas = self.user:get_shared_accounts()
  for _,v in ipairs(sas) do
    local a = v:get_account()
    a:json_prep(self.user)
    insert(accounts,a)
  end

  return { json = { accounts = accounts } }
end



app:match('api-v1-auth',api_prefix .. '/auth', function(self)
  local user = User.read_auth(self)
  if not user then
    return { status = 401, json = { error = 'endpoint requires authorization' } }
  end
  return { json = { token = user.access_token } }
end)

app:match('api-v1-account',api_prefix .. '/account(/:id)', respond_to({
  before = read_bearer,
  GET = function(self)
    return get_account(self, self.params.id)
  end,
  DELETE = function(self)
    if not self.params.id then
      return { status = 400, json = { error = 'missing parameter: account_id' } }
    end

    local account = Account:find({ id = self.params.id })
    if not account then
      return { status = 400, json = { error = 'unauthorized to use that account' } }
    end

    local shared = account:check_owner(self.user)

    local sas = account:get_streams_accounts()
    for _,sa in pairs(sas) do
      if shared then
        if sa:get_stream():get_user().id == self.user.id then
          sa:get_keystore():unset_all()
          sa:delete()
        end
      else
        sa:get_keystore():unset_all()
        sa:delete()
      end
    end

    if shared then
      local sa = SharedAccount:find({
        account_id = account.id,
        user_id = self.user.id,
      })
      sa:delete()
    else
      local ssas = account:get_shared_accounts()
      if not ssas then ssas = {} end
      for _,sa in pairs(ssas) do
        sa:delete()
      end
      account:get_keystore():unset_all()
      account:delete()
    end

    return { json = { status = 'success' } }
  end,
  POST = json_params(function(self)
    if not self.req.headers['content-type'] or
      self.req.headers['content-type'] ~= 'application/json' then
      return { status = 400, json = { error = 'content-type must be application/json' } }
    end
    -- incoming request:
    -- {
    --   "settings": {
    --     "name": "something",
    --     ...
    --   },
    --   "ffmpeg_args":"",
    -- }
    if not self.params.id then
      return { status = 400, json = { error = 'missing parameter: account_id' } }
    end

    local account = Account:find({ id = self.params.id })
    if not account then
      return { status = 400, json = { error = 'unauthorized to use that account' } }
    end
    if not account:check_owner(self.user) then
      return { status = 400, json = { error = 'unauthorized to use that account' } }
    end

    if networks[account.network].create_form then
      for _,v in ipairs(networks[account.network].create_form()) do
        if self.params.settings[v.key] then
          if self.params.settings[v.key] ~= cjson.null then
            account:set(v.key,self.params.settings[v.key])
            -- special key - name
            if v.key == 'name' then
              account:update({ name = self.params.settings[v.key] })
            end
          elseif self.params.settings[v.key] == cjson.null then
            account:unset(v.key)
          end
        end
      end
    end

    if self.params.ffmpeg_args then
      if self.params.ffmpeg_args ~= cjson.null then
        account:update({ ffmpeg_args = self.params.ffmpeg_args })
      elseif self.params.ffmpeg_args == cjson.null then
        account:update({ ffmpeg_args = db.NULL })
      end
    end

    if self.params.shares then
      if self.params.shares == cjson.null then
        for _,v in ipairs(account:get_shared_accounts()) do
            v:delete()
        end
      else
        for _,v in ipairs(self.params.shares) do
          local sa = SharedAccount:find({
            account_id = account.id,
            user_id = v.user.id
          })
          if not sa then
            SharedAccount:create({
              account_id = account.id,
              user_id = v.user.id,
            })
          end
        end
      end
    end
    return get_account(self, account.id)
  end)
}))

app:match('api-v1-stream',api_prefix .. '/stream(/:id)', respond_to({
  before = read_bearer,
  GET = function(self)
    return get_stream(self, self.params.id)
  end,
  PATCH = json_params(function(self)
    if not self.params.id then
      return { status = 400, json = { error = 'missing parameter: stream_id' } }
    end

    local stream = Stream:find({ id = self.params.id })
    if not stream then
      return { status = 400, json = { error = 'unauthorized to use that stream' } }
    end

    local meta_level = stream:check_meta(self.user)

    if meta_level < 2 then
      return { status = 400, json = { error = 'unauthorized to use that stream' } }
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

    if self.params.data_pulling == true and stream_status.data_pulling == false then
      stream_status.data_pulling = true
      publish('process:start:pull', {
        worker = pid,
        id = stream.id,
      })
    end

    if self.params.data_pulling == false and stream_status.data_pulling == true then
      stream_status.data_pulling = false
      publish('process:end:pull', {
        worker = pid,
        id = stream.id,
      })
    end

    if self.params.data_pushing == true and stream_status.data_pushing == false then
      stream_status.data_pushing = true

      for _,account in pairs(stream:get_accounts()) do
        local sa = StreamAccount:find({stream_id = stream.id, account_id = account.id})
        local rtmp_url, err = networks[account.network].publish_start(account:get_keystore(),sa:get_keystore())
        if (not rtmp_url) or err then
          return { status = 400, json = { error = err } }
        end
        sa:update({rtmp_url = rtmp_url})
      end

      publish('process:start:push', {
        worker = pid,
        id = stream.id,
      })

      publish('stream:start', {
        worker = pid,
        id = stream.id,
        status = stream_status,
      })
    end

    if self.params.data_pushing == false and stream_status.data_pushing == true then
      stream_status.data_pushing = false
      publish('stream:end', {
        id = stream.id,
      })

      publish('process:end:push', {
        id = stream.id,
      })
    end

    streams_dict:set(stream.id, to_json(stream_status))

    return { json = { status = stream_status } }

  end),
  DELETE = function(self)
    if not self.params.id then
      return { status = 400, json = { error = 'missing parameter: stream_id' } }
    end

    local stream = Stream:find({ id = self.params.id })
    if not stream then
      return { status = 400, json = { error = 'unauthorized to use that stream' } }
    end

    if not stream:check_owner(self.user) then
      return { status = 400, json = { error = 'unauthorized to use that stream' } }
    end

    local sas = stream:get_streams_accounts()
    for _,sa in pairs(sas) do
      sa:get_keystore():unset_all()
      sa:delete()
    end
    for _,ss in pairs(stream:get_stream_shares()) do
      ss:delete()
    end
    stream:get_keystore():unset_all()
    for _,w in pairs(stream:get_webhooks()) do
      w:delete()
    end
    publish('stream:delete',stream)
    stream:delete()

    return { json = { status = 'success' } }
  end,
  POST = json_params(function(self)
    if not self.req.headers['content-type'] or
      self.req.headers['content-type'] ~= 'application/json' then
      return { status = 400, json = { error = 'content-type must be application/json' } }
    end
    -- incoming request:
    -- {
    --   "name":"",
    --   "preview_required":"",
    --   "ffmpeg_pull_args":"",
    --   "title":"",
    --   "description":"",
    --   "accounts": [
    --     {
    --       "id":1,
    --       "setttings": {
    --         "key":"value",
    --         ...
    --       },
    --     },
    --     ...
    --   ],
    --   "shares" : [
    --     { "chat_level": 2,
    --       "metadata_level": 2,
    --       "user" : {
    --         "id": 1,
    --       }
    --     }
    --   ]
    -- }
    local stream, err
    if self.params.id then
      stream = Stream:find({ id = self.params.id })
      local meta_level = stream:check_meta(self.user)
      if meta_level < 2 then
        return { status = 401, json = { error = 'unauthorized to edit stream' } }
      end
    end

    -- prep for save_stream
    -- doesn't save key/value items for stream or accounts
    if not self.params.name then
      if not stream then
        return { status = 400, json = { error = 'name needed when making new stream' } }
      end
      self.params.name = stream.name
    end

    self.params.stream_name = self.params.name
    local og_accounts = self.params.accounts
    local og_shares = self.params.shares
    local og_webhooks = self.params.webhooks
    self.params.webhooks = nil

    if og_accounts then
      self.params.accounts = {}

      for _,acc in ipairs(self.user:get_accounts()) do
        self.params.accounts[acc.id] = false
      end
      for _, sa in ipairs(self.user:get_shared_accounts()) do
        self.params.accounts[sa.account_id] = false
      end

      for _,v in ipairs(og_accounts) do
        if v.id then
          self.params.accounts[v.id] = true
        end
      end
    end

    stream, err = Stream:save_stream(self.user,stream,self.params)

    if not stream then
      return { status = 400, json = { error = err } }
    end

    if self.params.title then
      stream:set('title',self.params.title)
    end
    if self.params.description then
      stream:set('description',self.params.description)
    end

    if og_accounts then
      for _,acc in ipairs(og_accounts) do
        local account = Account:find({ id = acc.id })

        if not account then
          return { status = 400, json = { error = 'unauthorized to use that account' } }
        end
        if not account:check_user(self.user) then
          return { status = 400, json = { error = 'unauthorized to use that account' } }
        end

        local sa = StreamAccount:find({ account_id = account.id, stream_id = stream.id })
        local metadata_fields = networks[account.network].metadata_fields()
        if acc.ffmpeg_args and acc.ffmpeg_args ~= cjson.null then
          sa:update({ ffmpeg_args = acc.ffmpeg_args })
        elseif acc.ffmpeg_args == cjson.null then
          sa:update({ ffmpeg_args = db.NULL })
        end

        for _,f in pairs(metadata_fields) do
          if f.required and not acc.settings or not acc.settings[f.key] then
            return { status = 400, json = { error = 'missing required field ' .. f.key } }
          end
          if acc.settings[f.key] then
            sa:set(f.key,acc.settings[f.key])
          else
            sa:unset(f.key)
          end
        end
      end
    end

    if og_shares then
      if og_shares == cjson.null then
        for _,v in ipairs(stream:get_stream_shares()) do
          v:delete()
        end
      else
        for _,v in ipairs(og_shares) do
          local ss = SharedStream:find({ stream_id = stream.id, user_id = v.user.id })
          if not ss then
            SharedStream:create({
              stream_id = stream.id,
              user_id = v.user.id,
              chat_level = v.chat_level,
              metadata_level = v.metadata_level,
            })
          else
            ss:update({
              chat_level = v.chat_level,
              metadata_level = v.metadata_level,
            })
          end
        end
      end
    end

    if og_webhooks then
      for _,w in pairs(stream:get_webhooks()) do
        w:delete()
      end
      if og_webhooks ~= cjson.null then
        for _,w in ipairs(og_webhooks) do
          local t = {}
          t.stream_id = stream.id
          t.url = w.url
          t.events = w.events
          t.notes = w.notes
          Webhook:create(t)
        end
      end
    end

    publish('stream:update',stream)
    return get_stream(self, stream.id)
  end),
}))

app:match('api-v1-me',api_prefix .. '/profile', respond_to({
  before = read_bearer,
  GET = function(self)
    return { json = self.user }
  end
}))

app:match('api-v1-users',api_prefix .. '/user', respond_to({
  before = read_bearer,
  GET = function(self)
    local users = User:select()
    for _,u in ipairs(users) do
      if u.id ~= self.user.id then
        u.access_token = nil
      end
      u.created_at = nil
      u.updated_at = nil
    end
    return { json = { users = users } }
  end
}))

return app
