local Model = require('lapis.db.model').Model
local pairs = pairs
local insert = table.insert
local concat = table.concat
local from_json = require('lapis.util').from_json
local to_json = require('lapis.util').to_json
local http = require'resty.http'
local unpack = unpack
if not unpack then
  unpack = table.unpack
end
local Account = require('models.account')

local Webhook_types = {
    [1] = {
        name = 'Discord',
        value = 'discord',
        events = {
          ['comment:in'] = function(hook,msg)
            local network = networks[msg.network]
            local username = msg.from.name .. ' @ ' .. network.displayname
            local content = msg.text

            local httpc = http.new()
            httpc:request_uri(hook.url, {
              method = 'POST',
              headers = {
                ['Content-Type'] = 'application/json',
              },
              body = to_json({
                content = content,
                username = username,
              }),
            })

          end,
          ['stream:start'] = function(hook, sas)
            local stream = hook:get_stream()
            local user = stream:get_user()
            local content = user.username .. ' is now streaming!'

            local urls = {}
            for _,v in pairs(sas) do
              local url = v:get('http_url')
              if url then
                insert(urls,url)
              end
            end

            if #urls > 0 then
              content = content .. ' ' .. concat(urls, ' ')
            end

            local httpc = http.new()
            httpc:request_uri(hook.url, {
              method = 'POST',
              headers = {
                ['Content-Type'] = 'application/json',
              },
              body = to_json({
                content = content,
                username = user.username,
              }),
            })
          end,
          ['stream:end'] = function(hook)
            local stream = hook:get_stream()
            local user = stream:get_user()
            local content = user.username .. ' has stopped streaming'

            local httpc = http.new()
            httpc:request_uri(hook.url, {
              method = 'POST',
              headers = {
                ['Content-Type'] = 'application/json',
              },
              body = to_json({
                content = content,
                username = user.username,
              }),
            })
          end
        }
    },
    [2] = {
        name = 'Raw',
        value = 'raw',
        events = {
          ['comment:in'] = function(hook,msg)
            msg.network = networks[msg.network]
            msg.stream = hook:get_stream()
            msg.stream_id = nil
            msg.account = Account:find({ id = msg.account_id })
            msg.account_id = nil
            msg.account.network = nil
            msg.user = msg.stream:get_user()
            msg.hook_type = 'comment:in'

            msg.user.updated_at = nil
            msg.user.created_at = nil
            msg.user.access_token = nil

            msg.stream.updated_at = nil
            msg.stream.created_at = nil
            msg.stream.user = nil
            msg.stream.user_id = nil
            msg.stream.uuid = nil
            msg.stream.preview_required = nil

            msg.network.write_comments = nil
            msg.network.read_comments = nil
            msg.network.allow_sharing = nil
            msg.network.icon = nil
            msg.network.redirect_uri = nil

            msg.account.keystore = nil
            msg.account.created_at = nil
            msg.account.updated_at = nil
            msg.account.network_user_id = nil
            msg.account.user_id = nil

            local httpc = http.new()
            httpc:request_uri(hook.url, {
              method = 'POST',
              headers = {
                ['Content-Type'] = 'application/json',
              },
              body = to_json(msg),
            })
          end,
          ['stream:start'] = function(hook,sas)
            local msg = {}
            msg.hook_type = 'stream:start'
            msg.stream = hook:get_stream()
            msg.user = msg.stream:get_user()
            msg.accounts = {}

            msg.user.updated_at = nil
            msg.user.created_at = nil
            msg.user.access_token = nil

            msg.stream.updated_at = nil
            msg.stream.created_at = nil
            msg.stream.user = nil
            msg.stream.user_id = nil
            msg.stream.uuid = nil
            msg.stream.preview_required = nil

            local urls = {}
            for _,v in pairs(sas) do
              local account = v:get_account()
              account.http_url = v:get('http_url')
              account.keystore = nil
              account.created_at = nil
              account.updated_at = nil
              account.network_user_id = nil
              account.user_id = nil
              if type(account.network) ~= 'table' then
                account.network = networks[account.network]
              end
              account.network.write_comments = nil
              account.network.read_comments = nil
              account.network.allow_sharing = nil
              account.network.icon = nil
              account.network.redirect_uri = nil
              insert(msg.accounts,account)
            end

            local httpc = http.new()
            httpc:request_uri(hook.url, {
              method = 'POST',
              headers = {
                ['Content-Type'] = 'application/json',
              },
              body = to_json(msg),
            })
          end,
          ['stream:end'] = function(hook)
            local msg = {}
            msg.hook_type = 'stream:end'
            msg.stream = hook:get_stream()
            msg.user = msg.stream:get_user()

            msg.user.updated_at = nil
            msg.user.created_at = nil
            msg.user.access_token = nil

            msg.stream.updated_at = nil
            msg.stream.created_at = nil
            msg.stream.user = nil
            msg.stream.user_id = nil
            msg.stream.uuid = nil
            msg.stream.preview_required = nil

            local httpc = http.new()
            httpc:request_uri(hook.url, {
              method = 'POST',
              headers = {
                ['Content-Type'] = 'application/json',
              },
              body = to_json(msg),
            })
          end
        }
    },
}

local Webhook_types_rev = {
    ['discord'] = 1,
    ['raw'] = 2,
}

local Webhook_events = {
    [1] = {
        name = 'Stream Start',
        value = 'stream:start',
    },
    [2] = {
        name = 'Stream End',
        value = 'stream:end',
    },
    [3] = {
        name = 'New Comment',
        value = 'comment:in',
    },
}

local Webhook = Model:extend('webhooks', {
  timestamp = true,
  relations = {
    {'stream', belongs_to = 'stream' },
  },
  fire_event = function(self, event, ...)
    if not self:check_event(event) then return end
    local event_func = Webhook_types[Webhook_types_rev[self.type]].events[event]
    if event_func then
      event_func(self,unpack({...}))
    end
  end,
  check_event = function(self,event)
    if not self.events then
      self.events = from_json(self.params).events
    end
    if self.events[event] == nil or self.events[event] == false then
      return false
    end
    return true
  end,
  enable_event = function(self, event)
    if not self.events then
      self.events = from_json(self.params).events
    end
    self.events[event] = true
  end,
  disable_event = function(self, event)
    if not self.events then
      self.events = from_json(self.params).events
    end
    self.events[event] = false
  end,
  save = function(self)
    return self:update({
      notes = self.notes,
      params = to_json({
        events = self.events
      })
    })
  end
})

function Webhook:create(params)
  local p = {
    events = params.events,
  }
  params.params = to_json(p)
  params.events = nil
  return Model.create(self,params)
end


Webhook.types_rev = Webhook_types_rev
Webhook.types = Webhook_types
Webhook.events = Webhook_events

return Webhook

