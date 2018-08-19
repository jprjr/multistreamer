-- luacheck: globals ngx networks
local ngx = ngx

local to_json   = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local cjson = require'cjson'
local db = require'lapis.db'

local User = require'multistreamer.models.user'
local Account = require'multistreamer.models.account'
local Stream = require'multistreamer.models.stream'
local StreamAccount = require'multistreamer.models.stream_account'
local SharedStream = require'multistreamer.models.shared_stream'
local SharedAccount = require'multistreamer.models.shared_account'
local Webhook = require'multistreamer.models.webhook'

local streams_dict = ngx.shared.streams

local insert = table.insert
local pairs = pairs
local ipairs = ipairs

local function export_stream(self, stream)
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
    return { status = 200, json = { stream = stream } }
  end
  return { status = 400, json = { error = 'unauthorized to access that stream' } }
end

local function import_stream(self, stream, params)
  if stream then
    local meta_level = stream:check_meta(self.user)
    if meta_level < 2 then
      return { status = 401, json = { error = 'unauthorized to edit stream' } }
    end
  end

  if not params.name then
    params.stream_name = stream.name
  else
    params.stream_name = params.name
  end
    
  local og_accounts = params.accounts
  local og_shares = params.shares
  local og_webhooks = params.webhooks
  params.webhooks = nil

  if og_accounts then
    params.accounts = {}

    for _,acc in ipairs(self.user:get_accounts()) do
      params.accounts[acc.id] = false
    end
    for _, sa in ipairs(self.user:get_shared_accounts()) do
      params.accounts[sa.account_id] = false
    end

    for _,v in ipairs(og_accounts) do
      if v.id then
        params.accounts[v.id] = true
      end
    end
  end

  stream, err = Stream:save_stream(self.user,stream,params)

  if not stream then
    return { status = 400, json = { error = err } }
  end

  if params.title then
    stream:set('title',params.title)
  end
  if params.description then
    stream:set('description',params.description)
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
      if not sa then
        sa = StreamAccount:create({ account_id = account.id, stream_id = stream.id })
      end

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
        t['type'] = w['type']
        Webhook:create(t)
      end
    end
  end

  return export_stream(self, stream)
end

return {
  import_stream = import_stream,
  export_stream = export_stream,
}
