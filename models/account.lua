local Model = require('lapis.db.model').Model
local Keystore = require'models.keystore'
local StreamAccount = require'models.stream_account'
local SharedAccount = require'models.shared_account'


local Account  = Model:extend('accounts', {
  timestamp = true,
  relations = {
    {'user', belongs_to = 'User' },
    {'streams_accounts', has_many = 'StreamAccount' },
    {'shared_accounts', has_many = 'SharedAccount' },
  },
  check_user = function(self,user)
    if self.user_id == user.id then
      return true, nil
    end
    local sa = SharedAccount:find({
      account_id = self.id,
      user_id = user.id,
    })
    if sa then
      return true, nil
    end
    return false, 'User not authorized for this account'
  end,
  check_owner = function(self,user)
    if self.user_id ~= user.id then
      return false, 'User not authorized for this account'
    end
    return true, nil
  end,
  check_network = function(self,network)
    if (self.network ~= network.name) then
      return false, 'Stream/Network module mismatch'
    end
    return true, nil
  end,
  get_stream_account = function(self,stream)
    return StreamAccount:find({
      stream_id = stream.id,
      account_id = self.id,
    })
  end,
  get_keystore = function(self)
    if not self.keystore then
      self.keystore = Keystore('keystore',self.id)
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
    return self:get_keystore():unset(key,value)
  end,
  share = function(self,user_id)
    local s_account = SharedAccount:find({account_id = self.id, user_id = user_id})
    if not s_account then
      SharedAccount:create({
        account_id = self.id,
        user_id = user_id,
      })
    end
  end,
  unshare = function(self,user_id)
    local s_account = SharedAccount:find({account_id = self.id, user_id = user_id})
    if s_account then
      s_account:delete()
    end
  end,
})

function Account:create(parms)
  local account_exists = self:check_unique_constraint({
    user_id = parms.user_id,
    network = parms.network,
    network_user_id = parms.network_user_id,
  })

  if not account_exists then
    return Model.create(self,parms)
  else
    return nil, 'Account not unique'
  end
end

function Account:create_post_handler(network)
  return function(res)
    if not res.account then
      res.account, err = self:create({
        user_id = res.user.id,
        network = network.name,
        name = res.params.name,
        network_user_id = res.params.network_user_id,
      })
      if res.account then
        return true, nil
      else
        return false, err
      end
    else
      res.account:update({
        name = res.params.name,
        account_token = res.params.account_token,
      })
      if res.account then
        return true, nil
      end
    end
  end
end


return Account;

