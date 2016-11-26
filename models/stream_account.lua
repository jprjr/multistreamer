local Model = require('lapis.db.model').Model
local Keystore = require'models.keystore'

local StreamAccount = Model:extend('streams_accounts', {
  primary_key = { 'account_id', 'stream_id' },
  relations = {
    { 'account', belongs_to = 'Account' },
    { 'stream', belongs_to = 'Stream' },
  },
  get_keystore = function(self)
    if not self.keystore then
      self.keystore = Keystore(self.account_id, self.stream_id)
    end
    return self.keystore
  end,
  set = function(self,key,value,exp)
    return self:get_keystore():set(key,value,exp)
  end,
  get = function(self,key)
    return self:get_keystore():get(key)
  end,
  get_all = function(self)
    return self:get_keystore():get_all()
  end,
  unset = function(self,key)
    return self:get_keystore():unset(key)
  end,
})

return StreamAccount



