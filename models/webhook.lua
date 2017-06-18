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
}

local Webhook_types_rev = {
    ['discord'] = 1,
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

