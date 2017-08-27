local Model = require('lapis.db.model').Model

local SharedAccount = Model:extend('shared_accounts', {
  primary_key = { 'user_id', 'account_id' },
  timestamp = true,
  relations = {
    { 'account', belongs_to = 'Account' },
    { 'user', belongs_to = 'User' },
  },
})

return SharedAccount



