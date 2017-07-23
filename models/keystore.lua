local db = require'lapis.db'
local date = db.format_date
local time = os.time
local insert = table.insert
local pairs = pairs

local Keystore = {}

local function keystore_new(_, account_id, stream_id)
  local m = {}
  m.account_id = account_id
  m.stream_id = stream_id

  if m.account_id and m.stream_id then
    m.query_string =
      'value, extract(epoch from expires_at - (now() at time zone \'UTC\')) as ' ..
      'expires_in, extract(epoch from expires_at) as expires_at from keystore w' ..
      'here account_id = ? and stream_id = ? and key = ? and (expires_at > (now' ..
      '() at time zone \'UTC\') or expires_at is null)'
    m.query_all_string =
      'key, value, extract(epoch from expires_at - (now() at time zone \'UTC\')' ..
      ') as expires_in, extract(epoch from expires_at) as expires_at from keyst' ..
      'ore where account_id = ? and stream_id = ? and (expires_at > (now() at t' ..
      'ime zone \'UTC\') or expires_at is null)'
  elseif not m.stream_id then
    m.query_string =
      'value, extract(epoch from expires_at - (now() at time zone \'UTC\')) as ' ..
      'expires_in, extract(epoch from expires_at) as expires_at from keystore w' ..
      'here account_id = ? and stream_id is NULL and key = ? and (expires_at > ' ..
      '(now() at time zone \'UTC\') or expires_at is null)'
    m.query_all_string =
      'key, value, extract(epoch from expires_at - (now() at time zone \'UTC\')' ..
      ') as expires_in, extract(epoch from expires_at) as expires_at from keyst' ..
      'ore where account_id = ? and stream_id is NULL and (expires_at > (now() ' ..
      'at time zone \'UTC\') or expires_at is null)'
  else
    m.query_string =
      'value, extract(epoch from expires_at - (now() at time zone \'UTC\')) as ' ..
      'expires_in, extract(epoch from expires_at) as expires_at from keystore w' ..
      'here account_id is NULL and stream_id = ? and key = ? and (expires_at > ' ..
      '(now() at time zone \'UTC\') or expires_at is null)'
    m.query_all_string =
      'key, value, extract(epoch from expires_at - (now() at time zone \'UTC\')' ..
      ') as expires_in, extract(epoch from expires_at) as expires_at from keyst' ..
      'ore where account_id is NULL and stream_id = ? and (expires_at > (now() ' ..
      'at time zone \'UTC\') or expires_at is null)'
  end

  m.get_all = function(self)
    local r = {}
    local res
    if(m.stream_id and m.account_id) then
      res = db.select(self.query_all_string,
        self.account_id,
        self.stream_id)
    else
      res = db.select(self.query_all_string,
        self.account_id or self.stream_id)
    end
    if res then
      for _,v in pairs(res) do
        r[v.key] = v.value
        if v.expires_in then
          r[v.key .. '.expires_in'] = v.expires_in
          r[v.key .. '.expires_at'] = v.expires_at
        end
      end
    end
    return r
  end

  m.get_keys = function(self)
    local res
    local keys = {}
    if(m.stream_id and m.account_id) then
      res = db.select('key from keystore where account_id = ? and stream_id = ?',
        self.account_id,
        self.stream_id)
    elseif m.stream_id then
      res = db.select('key from keystore where account_id is NULL and stream_id=?',
        self.stream_id)
    else
      res = db.select('key from keystore where account_id is ? and account_id is NULL',
        self.stream_id)
    end
    if res then
      for _,v in pairs(res) do
        insert(keys,v.key)
      end
    end
    return keys
 end

  m.get = function(self,key)
    local res
    if(m.stream_id and m.account_id) then
      res = db.select(self.query_string,
        self.account_id,
        self.stream_id,
        key)
    else
      res = db.select(self.query_string,
        self.account_id or self.stream_id,
        key)
    end
    if res and res[1] then
      return res[1].value, res[1].expires_in, res[1].expires_at
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
    local s_id = db.NULL
    local a_id = db.NULL
    if self.stream_id then
      s_id = self.stream_id
    end
    if self.account_id then
      a_id = self.account_id
    end

    local res = db.update('keystore',{
        value = value,
        updated_at = dt,
        expires_at = exp,
    }, {
        stream_id = s_id,
        account_id = a_id,
        key = key,
    })
    if res.affected_rows == 0 then
        res = db.insert('keystore',{
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
    db.delete('keystore',{
      stream_id = self.stream_id,
      account_id = self.account_id,
      key = key,
    })
    return true,nil
  end

  m.unset_all = function(self)
    db.delete('keystore',{
      stream_id = self.stream_id,
      account_id = self.account_id,
    })
    return true,nil
  end

  return m
end

setmetatable(Keystore, { __call = keystore_new } )

return Keystore
