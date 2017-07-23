local Account = require'models.account'
local StreamAccount = require'models.stream_account'

local config = require'multistreamer.config'
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'
local slugify = require('lapis.util').slugify

local M = {}

M.name = 'rtmp'
M.displayname = 'Custom RTMP'
M.allow_sharing = true
M.read_comments = false
M.write_comments = false

function M.create_form()
  return {
    [1] = {
      type = 'text',
      label = 'Name',
      key = 'name',
    },
    [2] = {
      type = 'text',
      label = 'RTMP URL',
      key = 'url',
      required = true,
    },
    [3] = {
      type = 'text',
      label = 'Shareable URL',
      key = 'http_url',
      required = false,
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
      slug = slugify(params.name),
    })
    if not account then
        return false, nil, err
    end
  else
    account:update({
      name = params.name,
      slug = slugify(params.name),
    })
  end

  account:set('http_url',params.http_url)
  account:set('url',params.url)
  account:set('name',params.name)

  local sa = nil
  if params.stream_id then
    sa = StreamAccount:find({ account_id = account.id, stream_id = params.stream_id })
    if not sa then
      sa = StreamAccount:create({ account_id = account.id, stream_id = params.stream_id })
    end
  end

  return account, sa, nil
end

function M.publish_start(account, stream)
  local rtmp_url = account:get('url')
  local http_url = account:get('http_url')

  if http_url then
    stream:set('http_url',http_url)
  end
  return rtmp_url, nil
end

function M.publish_stop(account, stream)
  stream:unsert('http_url')
  return true, nil
end

function M.check_errors(account)
  return false
end

function M.notify_update(account, stream)
  return true
end

function M.create_comment_funcs(account, stream, send)
  return nil,nil
end

function M.create_viewcount_func(account, stream, send)
  return nil,nil
end

return M

