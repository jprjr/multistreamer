local ngx = ngx
local config = require'helpers.config'
local encode_query_string = require('lapis.util').encode_query_string
local encode_base64 = require('lapis.util.encoding').encode_base64
local decode_base64 = require('lapis.util.encoding').decode_base64
local encode_with_secret = require('lapis.util.encoding').encode_with_secret
local decode_with_secret = require('lapis.util.encoding').decode_with_secret
local to_json   = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local http = require'resty.http'
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'
local format = string.format
local insert = table.insert
local sort = table.sort
local floor = math.floor
local facebook_config = config.networks.facebook

local Account = require'models.account'

local M = {}

M.displayname = 'Facebook'
M.allow_sharing = false

M.read_comments = true
M.write_comments = false

local graph_root = 'https://graph.facebook.com/v2.8'

local function facebook_client(access_token)
  if not access_token then
    return false,'access_token required'
  end

  local f = {}
  f.httpc = http.new()
  f.access_token = access_token

  f.request = function(self,method,endpoint,params,headers,body)
    local uri = graph_root .. endpoint
    if params then
      uri = uri .. '?' .. encode_query_string(params)
    end

    if body then
      ngx.log(ngx.DEBUG,body)
    end

    local res, err = self.httpc:request_uri(uri, {
      method = method,
      headers = headers,
      body = body,
    })
    if err then
      ngx.log(ngx.DEBUG,err)
      return false, err
    end

    if res.status >= 400 then
      ngx.log(ngx.DEBUG,res.body)
      return false, res.body
    end

    return from_json(res.body), nil
  end

  f.get = function(self,endpoint,params,headers)
    if not params then params = {} end
    params.access_token = self.access_token
    return self:request('GET',endpoint,params,headers)
  end

  f.post = function(self,endpoint,params,headers)
    if not params then params = {} end
    params.access_token = self.access_token
    return self:request('POST',endpoint,nil,headers,encode_query_string(params))
  end

  f.batch = function(self,requests,headers)
    local params = {
      access_token = self.access_token,
      include_headers = 'false',
      batch = to_json(requests),
    }
    return self:post('/',params,headers)
  end

  return f
end

function M.get_oauth_url(user)
  return 'https://www.facebook.com/v2.8/dialog/oauth?' ..
    encode_query_string({
      state = encode_base64(encode_with_secret({ id = user.id })),
      redirect_uri = M.redirect_uri,
      client_id = facebook_config.app_id,
      scope = 'user_events,user_managed_groups,publish_actions,manage_pages,publish_pages',
    })
end

function M.register_oauth(params)
  local user, err = decode_with_secret(decode_base64(params.state))

  if not user then
    return false, 'error'
  end

  if not params.code then
    return false, 'error'
  end

  local httpc = http.new()

  -- first exchange the 'code' for a short-lived access token
  local res, err = httpc:request_uri(graph_root .. '/oauth/access_token?' ..
    encode_query_string({
      client_id = facebook_config.app_id,
      redirect_uri = M.redirect_uri,
      client_secret = facebook_config.app_secret,
      code = params.code,
    }))

  if err or res.status >= 400 then
    return false, err
  end

  local creds = from_json(res.body)

  -- then, echange the short-lived token for a long-lived token
  res, err = httpc:request_uri(graph_root .. '/oauth/access_token?' ..
    encode_query_string({
      grant_type = 'fb_exchange_token',
      client_id = facebook_config.app_id,
      client_secret = facebook_config.app_secret,
      fb_exchange_token = creds.access_token}))

  if err or res.status >= 400 then
      return false, err
  end
  creds = from_json(res.body)

  -- now, we can make the facebook client object

  local fb_client = facebook_client(creds.access_token)

  local user_info, err = fb_client:get('/me')
  if err then return false, err end

  local sha1 = resty_sha1:new()
  sha1:update(user_info.id)
  local network_user_id = str.to_hex(sha1:final())

  local account = Account:find({
    network = M.name,
    network_user_id = network_user_id,
  })

  if not account then
    account = Account:create({
      user_id = user.id,
      network = M.name,
      network_user_id = network_user_id,
      name = user_info.name,
    })
  end

  if(creds.expires_in) then
    account:set('access_token',creds.access_token, tonumber(creds.expires_in))
  else
    local old_tok, old_exp = account:get('access_token')
    account:set('access_token',creds.access_token,floor(old_exp))
  end

  local available_targets = {
    [user_info.id] = {
      type = 'profile',
      name = user_info.name,
      token = creds.access_token,
    }
  }


  local page_info, page_info_err

  repeat
    local after
    if page_info and page_info.paging and page_info.paging.cursors then
        after = page_info.paging.cursors.after
    end
    page_info, page_info_err = fb_client:get('/me/accounts', {
      after = after
    })
    for i,page in pairs(page_info.data) do
      local name = page.name
      local id = page.id
      local access_token = page.access_token

      available_targets[id] = {
        type = 'page',
        name = name,
        token = access_token,
      }
    end
  until page_info.paging.next == nil

  account:set('targets',to_json(available_targets))

  if account.user_id ~= user.id then
    return false, "Account already registered"
  end

  return account, nil

end

function M.metadata_form(account, stream)
  local form = M.metadata_fields()
  local targets = from_json(account:get('targets'))
  local keys = {}
  for k in pairs(targets) do insert(keys,k) end
  sort(keys,function(a,b)
    local a_type = targets[a].type
    local b_type = targets[b].type

    if a_type ~= b_type then
      if a_type == 'profile' then
        return true
      end
      return false
    end
    return targets[a].name < targets[b].name
  end)

  for _,k in pairs(keys) do
    local acc_type = targets[k].type
    local name = targets[k].name

    if acc_type == 'profile' then
      name = name .. ' (Profile)'
    elseif acc_type == 'page' then
      name = name .. ' (Page)'
    end
    insert(form[3].options,
      { value = k,
        label = name,
      }
    )
  end

  for i,v in pairs(form) do
    v.value = stream:get(v.key)
  end

  return form

end

function M.metadata_fields()
  return {
    [1] = {
      type = 'text',
      label = 'Video Title',
      key = 'title',
      required = true,
    },
    [2] = {
      type = 'textarea',
      label = 'Description',
      key = 'description',
      required = true,
    },
    [3] = {
      type = 'select',
      label = 'Profile/Page',
      key = 'target',
      required = true,
      options = {},
    },
    [4] = {
      type = 'select',
      label = 'Privacy (N/A to Pages)',
      key = 'privacy',
      required = false,
      options = {
          { value = 'SELF',label = 'Myself Only' },
          { value = 'ALL_FRIENDS',label = 'Friends' },
          { value = 'FRIENDS_OF_FRIENDS',label = 'Friends of Friends' },
          { value = 'EVERYONE',label = 'Public' },
      },
    },
    [5] = {
      type = 'select',
      label = 'Continuous (>4 hours) video?',
      key = 'stream_type',
      required = true,
      options = {
          { value = 'REGULAR', label = 'No' },
          { value = 'AMBIENT', label = 'Yes' },
      },
    }
  }

end

function M.publish_start(account, stream)
  local stream_o = stream
  local account = account:get_all()
  local stream = stream:get_all()

  local targets = from_json(account.targets)
  local target = targets[stream.target]

  local access_token = target.token
  local privacy = stream.privacy
  local stream_type = stream.stream_type
  local description = stream.description
  local title = stream.title

  local params = {}

  if privacy and target.type == 'profile' then
    params['privacy[value]'] = privacy
  end

  params.description = description
  params.title = title
  params.stream_type = stream_type
  params.status = 'LIVE_NOW'
  params.stop_on_delete_stream = 'false'

  local fb_client = facebook_client(access_token)

  local vid_info, err = fb_client:post('/'..stream.target..'/live_videos',params)

  if err then
    return false, to_json(err)
  end

  local more_vid_info, err = fb_client:get('/' .. vid_info.id, {
    fields = 'permalink_url',
  })
  if err then
    return false, to_json(err)
  end

  stream_o:set('http_url','https://facebook.com' .. more_vid_info.permalink_url)
  stream_o:set('video_id',vid_info.id)

  return vid_info.stream_url, nil
end

function M.publish_stop(account, stream)
  local stream_o = stream

  local account = account:get_all()
  local stream = stream:get_all()

  stream_o:unset('http_url')
  stream_o:unset('video_id')

  local targets = from_json(account.targets)
  local target = targets[stream.target]

  local access_token = target.token

  local video_id = stream.video_id
  local fb_client = facebook_client(access_token)

  if(video_id) then
    fb_client:post('/'..video_id, {
      end_live_video = 'true',
    })
  end

  return true
end

function M.check_errors(account)
  local token, exp = account:get('access_token')
  if not token then
    return 'Needs refresh'
  end

  if exp and exp < 864000 then -- if token expires in <10 days
    local httpc = http.new()

    local res, err = httpc:request_uri(graph_root .. '/oauth/access_token?' ..
      encode_query_string({
        access_token = token,
        client_id = facebook_config.app_id,
        client_secret = facebook_config.app_secret,
        redirect_uri = M.redirect_uri,
      })
    )

    if err or res.status >= 400 then
      return 'Token expiring soon, unable to refresh'
    end

    local code = from_json(res.body).code

    res, err = httpc:request_uri(graph_root .. '/oauth/access_token?' ..
      encode_query_string({
        code = code,
        client_id = facebook_config.app_id,
        redirect_uri = M.redirect_uri,
      })
    )

    if err or res.status >= 400 then
      return 'Token expiring soon, unable to refresh'
    end

    local creds = from_json(res.body)
    account:set('access_token',creds.access_token, tonumber(creds.expires_in))
  end


  return false
end

function M.notify_update(account, stream)
  return true
end

local emotes = {
  ['LIKE'] = 'likes this',
  ['LOVE'] = 'loves this',
  ['WOW']  = 'is wowed by this',
  ['HAHA'] = 'is laughing at this',
  ['SAD']  = 'is saddened by this',
  ['ANGRY'] = 'is made angry by this',
  ['THANKFUL'] = 'is thankful for this',
}

local function textify(emote)
  local text = emotes[emote]
  if not text then
    text = 'hit some kind of new reaction button that I don\'t know about'
  end
  return text
end

function M.create_comment_funcs(account, stream, send)
  local account = account:get_all()
  local stream = stream:get_all()

  local targets = from_json(account.targets)
  local target = targets[stream.target]
  local access_token = target.token

  local video_id = stream.video_id
  local fb_client = facebook_client(access_token)

  local read_func = function()
    local afterComment = nil
    local afterReaction = nil
    while true do
      local res, err = fb_client:batch({
        {
          method = 'GET',
          relative_url = video_id .. '/comments?' .. encode_query_string({after = afterComment}),
        },
        {
          method = 'GET',
          relative_url = video_id .. '/reactions?' .. encode_query_string({after = afterReaction}),
        }
      })
      if res[1].code == 200 then
        local body = from_json(res[1].body)
        if body.paging then afterComment = body.paging.cursors.after end
        for i,v in pairs(body.data) do
          send({
            type = 'text',
            from = {
              name = v.from.name,
              id = v.from.id,
            },
            text = v.message,
          })
        end
      end
      if res[2].code == 200 then
        local body = from_json(res[2].body)
        if body.paging then afterReaction = body.paging.cursors.after end
        for i,v in pairs(body.data) do
          send({
            type = 'emote',
            from = {
              name = v.name,
              id = v.id,
            },
            text = textify(v.type)
          })
        end
      end
      ngx.sleep(6)
    end
  end

  local write_func = nil

  return read_func, write_func
end


return M
