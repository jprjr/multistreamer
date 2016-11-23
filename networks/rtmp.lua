local Account = require'models.account'

local config = require('lapis.config').get()
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'

local M = {}

M.displayname = 'Custom RTMP'
M.allow_sharing = true

function M.create_form()
  return {
    [1] = {
      type = 'text',
      label = 'Name',
      key = 'name',
    },
    [2] = {
      type = 'text',
      label = 'URL',
      key = 'url',
      required = true,
    },
  }
end

function M.metadata_fields()
  return nil,nil
end


function M.metadata_form(account_keystore, stream_keystore)
  return nil,nil
end

function M.save_account(user, account, params)
  -- check that account doesn't already exists
  local account = account
  local err

  local sha1 = resty_sha1:new()
  sha1:update(params.url)
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
      name = params.name,
      user_id = user.id,
    })
    if not account then
        return false,err
    end
  else
    account:update({
      name = params.name,
    })
  end

  account:set('url',params.url)
  account:set('name',params.name)

  return account, nil
end

function M.publish_start(account, stream)
  return account:get('url')
end

function M.check_errors(account)
  return false
end

return M

