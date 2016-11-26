local db = require'lapis.db'
local date = db.format_date
local time = os.time
local insert = table.insert

local Keystore = {}

local function keystore_new(_, account_id, stream_id)
  local m = {}
  m.account_id = account_id
  m.stream_id = stream_id

  if m.account_id and m.stream_id then
    m.query_string = 'value, extract(epoch from expires_at - (now() at time zone \'UTC\')) as expires_in from keystore where account_id = ? and stream_id = ? and key = ? and (expires_at > (now() at time zone \'UTC\') or expires_at is null)'
    m.query_all_string = 'key, value, extract(epoch from expires_at - (now() at time zone \'UTC\')) as expires_in from keystore where account_id = ? and stream_id = ? and (expires_at > (now() at time zone \'UTC\') or expires_at is null)'
  elseif not m.stream_id then
    m.query_string = 'value, extract(epoch from expires_at - (now() at time zone \'UTC\')) as expires_in from keystore where account_id = ? and stream_id is NULL and key = ? and (expires_at > (now() at time zone \'UTC\') or expires_at is null)'
    m.query_all_string = 'key, value, extract(epoch from expires_at - (now() at time zone \'UTC\')) as expires_in from keystore where account_id = ? and stream_id is NULL and (expires_at > (now() at time zone \'UTC\') or expires_at is null)'
  else
    m.query_string = 'value, extract(epoch from expires_at - (now() at time zone \'UTC\')) as expires_in from keystore where account_id is NULL and stream_id = ? and key = ? and (expires_at > (now() at time zone \'UTC\') or expires_at is null)'
    m.query_all_string = 'key, value, extract(epoch from expires_at - (now() at time zone \'UTC\')) as expires_in from keystore where account_id is NULL and stream_id = ? and (expires_at > (now() at time zone \'UTC\') or expires_at is null)'
  end

  m.get_all = function(self)
    local r = {}
    local res, err
    if(m.stream_id and m.account_id) then
      res, err = db.select(self.query_all_string,
        self.account_id,
        self.stream_id)
    else
      res, err = db.select(self.query_all_string,
        self.account_id or self.stream_id)
    end
    if res then
      for i,v in pairs(res) do
        r[v.key] = v.value
      end
    end
    return r
  end

  m.get_keys = function(self)
    local res, err
    local keys = {}
    if(m.stream_id and m.account_id) then
      res, err = db.select('key from keystore where account_id = ? and stream_id = ?',
        self.account_id,
        self.stream_id)
    elseif m.stream_id then
      res, err = db.select('key from keystore where account_id is NULL and stream_id=?',
        self.stream_id)
    else
      res, err = db.select('key from keystore where account_id is ? and account_id is NULL',
        self.stream_id)
    end
    if res then
      for i,v in pairs(res) do
        insert(keys,v.key)
      end
    end
    return keys
 end

  m.get = function(self,key)
    local res, err
    if(m.stream_id and m.account_id) then
      res, err = db.select(self.query_string,
        self.account_id,
        self.stream_id,
        key)
    else
      res, err = db.select(self.query_string,
        self.account_id or self.stream_id,
        key)
    end
    if res and res[1] then
      return res[1].value, res[1].expires_in
    end
    return nil
  end

  m.set = function(self,key,value,exp)
    local dt = date()
    if exp then
      exp = date(time() + exp)
    else
      exp = db.NULL
    end

    local res = db.update('keystore',{
        value = value,
        updated_at = dt,
        expires_at = exp,
    }, {
        stream_id = self.stream_id,
        account_id = self.account_id,
        key = key,
    })
    if res.affected_rows == 0 then
        local res = db.insert('keystore',{
            account_id = self.account_id,
            stream_id = self.stream_id,
            key = key,
            value = value,
            updated_at = dt,
            created_at = dt,
            expires_at = exp,
        })
        if not res then
            return false, 'Failed to create/update keystore'
        end
    end
    return true,nil
  end

  m.unset = function(self,key)
    local res = db.delete('keystore',{
        stream_id = self.stream_id,
        account_id = self.account_id,
        key = key,
    })
    return true,nil
  end

  m.unset_all = function(self,key)
    local res = db.delete('keystore',{
      stream_id = self.stream_id,
      account_id = self.account_id,
    })
    return true,nil
  end

  return m
end

setmetatable(Keystore, { __call = keystore_new } )

return Keystore
