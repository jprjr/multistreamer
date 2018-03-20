local migrations = require'lapis.db.migrations'
local schema     = require'lapis.db.schema'
local util       = require'lapis.util'
local types = schema.types

local Account = require'multistreamer.models.account'

local schemas = {
  [1477785578] = function()
    schema.create_table('users', {
      { 'id'      , types.serial },
      { 'username', types.varchar },
      { 'created_at', types.time },
      { 'updated_at', types.time },
      'PRIMARY KEY(id)'
    })

    schema.create_table('accounts', {
      { 'id'      , types.serial },
      { 'user_id' , types.foreign_key },
      { 'network' , types.varchar },
      { 'network_user_id', types.varchar },
      { 'name'    , types.varchar },
      { 'created_at', types.time },
      { 'updated_at', types.time },
      'PRIMARY KEY(id)',
      'FOREIGN KEY(user_id) REFERENCES users(id)',
    })

    schema.create_table('shared_accounts', {
      { 'user_id', types.foreign_key },
      { 'account_id', types.foreign_key },
      { 'created_at', types.time },
      { 'updated_at', types.time },
      'PRIMARY KEY(user_id,account_id)',
      'FOREIGN KEY(user_id) REFERENCES users(id)',
      'FOREIGN KEY(account_id) REFERENCES accounts(id)',
    })

    schema.create_table('streams', {
      { 'id', types.serial },
      { 'uuid', types.varchar },
      { 'user_id', types.foreign_key },
      { 'name' , types.varchar },
      { 'slug' , types.varchar },
      { 'created_at', types.time },
      { 'updated_at', types.time },
      'PRIMARY KEY(id)',
      'UNIQUE(uuid)',
      'FOREIGN KEY(user_id) REFERENCES users(id)',
    })

    schema.create_table('streams_accounts', {
      { 'stream_id', types.foreign_key },
      { 'account_id' , types.foreign_key },
      { 'rtmp_url', types.text({ null = true }) },
      'FOREIGN KEY(stream_id) REFERENCES streams(id)',
      'FOREIGN KEY(account_id) REFERENCES accounts(id)',
      'PRIMARY KEY(stream_id, account_id)',
    })

    schema.create_table('keystore', {
      { 'stream_id', types.foreign_key({ null = true }) },
      { 'account_id' , types.foreign_key({ null = true }) },
      { 'key' , types.varchar },
      { 'value', types.text },
      { 'created_at', types.time },
      { 'updated_at', types.time },
      { 'expires_at', types.time({ null = true }) },
      'FOREIGN KEY(stream_id) REFERENCES streams(id)',
      'FOREIGN KEY(account_id) REFERENCES accounts(id)',
    })

  end,

  [1481421931] = function()
    schema.add_column('accounts','slug',types.varchar)
    local accounts = Account:select()
    for _,v in ipairs(accounts) do
      v:update({
        slug = util.slugify(slug)
      })
    end
  end,

  [1485029477] = function()
    schema.add_column('streams_accounts','ffmpeg_args',types.text({ null = true }))
  end,

  [1485036089] = function()
    schema.add_column('accounts','ffmpeg_args',types.text({ null = true }))
  end,

  [1485788609] = function()
    schema.create_table('shared_streams', {
      { 'user_id', types.foreign_key },
      { 'stream_id', types.foreign_key },
      { 'chat_level', types.integer({ null = true }) },
      { 'metadata_level', types.integer({ null = true }) },
      { 'created_at', types.time },
      { 'updated_at', types.time },
      "PRIMARY KEY(user_id,stream_id)",
      "FOREIGN KEY(user_id) REFERENCES users(id)",
      "FOREIGN KEY(stream_id) REFEREnCES streams(id)",
    })
  end,

  [1489949143] = function()
    schema.add_column('streams','preview_required',types.integer)
    schema.add_column('streams','ffmpeg_pull_args',types.text({ null = true }))
    local Stream = require'multistreamer.models.stream'
    local streams = Stream:select()
    for _,v in ipairs(streams) do
      v:update({ preview_required = 0 })
    end
  end,

  [1492032677] = function()
    schema.add_column('users','access_token',types.varchar)
    local User = require'multistreamer.models.user'
    local users = User:select()
    for _,v in ipairs(users) do
      v:reset_token()
    end
  end,

  [1497734864] = function()
    schema.create_table('webhooks', {
      { 'id', types.serial },
      { 'stream_id', types.foreign_key },
      { 'url', types.text },
      { 'params', types.text({ null = true }) },
      { 'notes', types.text({ null = true }) },
      { 'type', types.varchar },
      { 'created_at', types.time },
      { 'updated_at', types.time },
      "PRIMARY KEY(id)",
      "FOREIGN KEY(stream_id) REFERENCES streams(id)",
    })
  end,

  [1500610370] = function()
    local Stream = require'multistreamer.models.stream'
    local streams = Stream:select()
    for _,v in ipairs(streams) do
      if v.network == 'beam' then
        v:update({ network = 'mixer' })
      end
    end
  end,

  [1503806092] = function()
    return true
  end,

  [1521568700] = function()
    schema.add_column('users','preferences',types.text({ default = "{}"}))
  end,

}

migrations.run_migrations(schemas)


