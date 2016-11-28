local Model = require('lapis.db.model').Model
local Keystore = require'models.keystore'
local Account = require'models.account'
local StreamAccount = require'models.stream_account'
local format = string.format

local Stream = Model:extend('streams', {
  timestamp = true,
  relations = {
    {'user', belongs_to = 'User' },
    {'streams_accounts', has_many = 'StreamAccount' },
  },
  check_user = function(self,user)
    if self.user_id ~= user.id then
      return false, 'Not authorized for this stream'
    end
    return true, nil
  end,
  get_stream_account = function(self,account)
    return StreamAccount:find({
      account_id = account.id,
      stream_id = self.id,
    })
  end,
  get_accounts = function(self)
    local accounts = {}
    local streams_accounts = self:get_streams_accounts()

    if streams_accounts then
      for i,v in pairs(streams_accounts) do
        local account = v:get_account()
        accounts[account.id] = account
      end
    end
    return accounts
  end,
  get_account = function(self, account)
    return self:get_accounts()[account.id]
  end,
  get_keystore = function(self)
    if not self.keystore then
      self.keystore = Keystore(nil,self.id)
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

function Stream:create(parms)
  parms.uuid = uuid()
  return Model.create(self,parms)
end


function Stream:save_stream(user,stream,params)
  local stream = stream
  if not stream then
    stream = self:create({
      user_id = user.id,
      name = params.stream_name
    })
  else
    stream:update({
      name = params.stream_name
    })
  end

  for id, value in pairs(params.accounts) do
    local sa = StreamAccount:find({
      stream_id = stream.id,
      account_id = id,
    })

    if sa and value == false then
      sa:delete()
    elseif( (not sa) and value == true) then
      StreamAccount:create({
        stream_id = stream.id,
        account_id = id,
      })
    end
  end

  if not stream then
    return false, 'Failed to save stream'
  end

  return stream, nil
end

return Stream;

