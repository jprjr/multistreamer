--luacheck: globals ngx networks
--local ngx = ngx
local Model = require('lapis.db.model').Model
local pairs = pairs
local insert = table.insert
local concat = table.concat
local from_json = require('lapis.util').from_json
local to_json = require('lapis.util').to_json
local http = require'resty.http'
local unpack = unpack or table.unpack -- luacheck: compat

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
            -- incoming message structure
            -- {
            --    type = 'text',
            --    from = {
            --      name = 'some-display-name',
            --      id = 'some-user-id',
            --    },
            --    text = 'plain-text message',
            --    markdown = 'markdown message'
            --    account_id = account_id,
            --    stream_id = stream_id,
            --    network = network
            -- }

            local network = networks[msg.network]
            local stream = hook:get_stream()
            local user = stream:get_user()

            local out_msg = {
              hook_type = 'comment:in',
              type = msg.type,
              text = msg.text,
              markdown = msg.markdown,
              network = {
                displayname = network.displayname,
                name = network.name,
              },
              account = {
                id = msg.account_id,
              },
              stream = {
                id = stream.id,
              },
              user = {
                username = user.username,
                id = user.id,
              }
            }

            local httpc = http.new()
            httpc:request_uri(hook.url, {
              method = 'POST',
              headers = {
                ['Content-Type'] = 'application/json',
              },
              body = to_json(out_msg),
            })
          end,
          ['stream:start'] = function(hook,sas)
            local stream = hook:get_stream()
            local user = stream:get_user()

            local out_msg = {
              hook_type = 'stream:start',
              accounts = {},
              user = {
                id = user.id,
                username = user.username,
              },
              stream = {
                id = stream.id,
                slug = stream.slug,
                name = stream.name,
              }
            }

            for _,v in pairs(sas) do
              local account = v:get_account()

              local a = {
                id = account.id,
                network = {
                  displayname = networks[account.network].displayname,
                  name = networks[account.network].name,
                },
                slug = account.slug,
                name = account.name,
                http_url = v:get('http_url')
              }

              insert(out_msg.accounts,a)
            end

            local httpc = http.new()
            httpc:request_uri(hook.url, {
              method = 'POST',
              headers = {
                ['Content-Type'] = 'application/json',
              },
              body = to_json(out_msg),
            })
          end,
          ['stream:end'] = function(hook)
            local stream = hook:get_stream()
            local user = stream:get_user()

            local out_msg = {
              hook_type = 'stream:end',
              user = {
                id = user.id,
                username = user.username,
              },
              stream = {
                id = stream.id,
                slug = stream.slug,
                name = stream.name,
              },
            }

            local httpc = http.new()
            httpc:request_uri(hook.url, {
              method = 'POST',
              headers = {
                ['Content-Type'] = 'application/json',
              },
              body = to_json(out_msg),
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
  change_type = function(self, typ)
    self.type = typ
  end,
  save = function(self)
    return self:update({
      notes = self.notes,
      type = self.type,
      params = to_json({
        events = self.events,
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

