local Model = require('lapis.db.model').Model

local SharedStrem = Model:extend('shared_streams', {
  primary_key = { 'user_id', 'stream_id' },
  timestamp = true,
  relations = {
    { 'stream', belongs_to = 'Stream' },
    { 'user', belongs_to = 'User' },
  },
})

return SharedStream



