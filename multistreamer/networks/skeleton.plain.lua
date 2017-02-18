local Account = require'models.account'

local config = require'multistreamer.config'
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'

local M = {}

M.displayname = 'Skeleton Non-OAuth Module'
M.allow_sharing = true

function M.create_form()
  return {
    [1] = {
      type = 'text',
      label = 'Account Field 1',
      key = 'field1',
    },
    [2] = {
      type = 'text',
      label = 'Account Field 2',
      key = 'field2',
      required = true,
    },
  }
end

function M.save_account(user, account, params)
  -- check that account doesn't already exists
  local account = account
  local err

  local sha1 = resty_sha1:new()
  sha1:update(params.field2)
  local url_key = str.to_hex(sha1:final())

  if not account then
    account, err = Account:find({
      network = M.network,
      network_user_id = url_key,
    })
  end

  if not account then
    account, err = Account:create({
      network = M.name,
      network_user_id = url_key,
      name = params.field1,
      user_id = user.id,
    })
    if not account then
        return false,err
    end
  else
    account:update({
      name = params.field1,
    })
  end

  account:set('field1',params.field1)
  account:set('field2',params.field2)

  return account, nil
end

function M.metadata_form(account, stream)
  local form = M.metadata_fields()

  -- add in some default values etc to the form
  return form

end

function M.metadata_fields()
  return {
    [1] = {
      type = 'text',
      label = 'Field 1',
      key = 'field1',
      required = true,
    },
    [2] = {
      type = 'text',
      label = 'Field 2',
      key = 'field2',
      required = true,
    },
  }

end

function M.publish_start(account, stream)
  local some_account_key = account:get('field1')
  local param1 = stream:get('field1')
  local param2 = stream:get('field2')

    local res, err = httpc:request_uri('http://example.com/update', {
      method = 'POST',
      body = to_json({param1 = param1, param2 = param2}),
    })

  if err or res.status >= 400 then
    return false, err or res.body
  end
  stream:set('http_url',http_url)

  return from_json(res.body).rtmp_url, nil
end

function M.publish_stop(account, stream)
  local some_account_key = account:get('field1')
  local param1 = stream:get('field1')
  local param2 = stream:get('field2')

  local res, err = httpc:request_uri('http://example.com/stop', {
    method = 'POST',
    headers = {
      ['Access'] = 'OAuth ' .. access_token,
    },
    body = to_json({param1 = param1, param2 = param2}),
  })

  stream:unset('http_url')

  return nil
end

function M.check_errors(account)
  return false,nil
end

function M.notify_update(account)
  return true
end

function M.create_comment_funcs(account, stream, send)
  return nil,nil
end

function M.create_viewcount_func(account, stream, send)
  return nil,nil
end

return M

