-- luacheck: globals ngx
local ngx = ngx
local config = require'multistreamer.config'
local encode_query_string = require('lapis.util').encode_query_string
local encode_base64 = require('lapis.util.encoding').encode_base64
local decode_base64 = require('lapis.util.encoding').decode_base64
local encode_with_secret = require('lapis.util.encoding').encode_with_secret
local decode_with_secret = require('lapis.util.encoding').decode_with_secret
local to_json   = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local slugify = require('lapis.util').slugify
local http = require'multistreamer.http'
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'
local insert = table.insert
local string = require 'multistreamer.string'
local len = string.len
local sort = table.sort
local format = string.format
local escape_markdown = string.escape_markdown
local date = require'date'
local ngx_log = ngx.log
local ngx_err = ngx.ERR
local ngx_debug = ngx.DEBUG
local facebook_config = config.networks.facebook

local Account = require'models.account'
local StreamAccount = require'models.stream_account'

local M = {}

M.name = 'facebook'
M.displayname = 'Facebook'
M.allow_sharing = false
M.read_comments = true
M.write_comments = false
M.redirect_uri = config.public_http_url .. config.http_prefix .. '/auth/facebook'

M.icon =
  '<svg viewBox="0 0 16 16" xmlns="http://www.w3.' ..
  'org/2000/svg" fill-rule="evenodd" clip-rule="evenodd" stroke-linejoin="r' ..
  'ound" stroke-miterlimit="1.414"><path d="M15.117 0H.883C.395 0 0 .395 0 ' ..
  '.883v14.234c0 .488.395.883.883.883h7.663V9.804H6.46V7.39h2.086V5.607c0-2' ..
  '.066 1.262-3.19 3.106-3.19.883 0 1.642.064 1.863.094v2.16h-1.28c-1 0-1.1' ..
  '95.48-1.195 1.18v1.54h2.39l-.31 2.42h-2.08V16h4.077c.488 0 .883-.395.883' ..
  '-.883V.883C16 .395 15.605 0 15.117 0" fill-rule="nonzero"/></svg>'


local graph_root = 'https://graph.facebook.com/v2.8'

local function http_error_handler(res)
  ngx_log(ngx_err,res.body)
  return from_json(res.body).error.message
end

local function facebook_client(access_token)
  if not access_token then
    return false,'access_token required'
  end

  local httpc = http.new(http_error_handler)
  local _request = httpc.request

  httpc.request = function(self,method,endpoint,params,headers,body)
    params = params or {}
    params.access_token = access_token

    local url = graph_root .. endpoint

    local res, err = _request(self,method,url,params,headers,body)
    if err then return false, err end

    return from_json(res.body), nil
  end

  httpc.get = function(self,endpoint,params,headers)
    return httpc.request(self,'GET',endpoint,params,headers)
  end

  httpc.post = function(self,endpoint,params,headers)
    return httpc.request(self,'POST',endpoint,nil,headers,encode_query_string(params))
  end

  httpc.batch = function(self,requests,headers)
    local params = {
      access_token = access_token,
      include_headers = 'false',
      batch = to_json(requests),
    }
    return httpc.post(self,'/',params,headers)
  end

  httpc.__index = httpc
  setmetatable(httpc,httpc)

  return httpc
end

function M.get_oauth_url(user, stream_id)
  return 'https://www.facebook.com/v2.8/dialog/oauth?' ..
    encode_query_string({
      state = encode_base64(encode_with_secret({ id = user.id, stream_id = stream_id })),
      redirect_uri = M.redirect_uri,
      client_id = facebook_config.app_id,
      scope = 'user_events,user_managed_groups,publish_actions,manage_pages,publish_pages',
    })
end

local function refresh_targets(access_token)
  local fb_client = facebook_client(access_token)
  local targets = {}
  local my_info, my_info_err = fb_client:get('/me', {
    fields = 'id,name'}
  )

  if my_info_err then return false, my_info_err end

  targets[my_info.id] = {
    type = 'profile',
    name = my_info.name,
    token = access_token,
  }
  -- todo - make this more efficient with batch requests

  local group_info, group_info_err
  repeat
    local after
    if group_info and group_info.paging and group_info.paging.cursors then
      after = group_info.paging.cursors.after
    end
    group_info, group_info_err = fb_client:get('/me/groups', {
      after = after,
      fields = 'id,name',
    })
    for _,group in pairs(group_info.data) do
      targets[group.id] = {
        type = 'group',
        name = group.name,
        token = access_token,
      }
    end
  until group_info_err or group_info.paging == nil or group_info.paging.next == nil

  local event_info, event_info_err
  local right_now = date(true)
  repeat
    local after
    if event_info and event_info.paging and event_info.paging.cursors then
      after = event_info.paging.cursors.after
    end
    event_info, event_info_err = fb_client:get('/me/events', {
      after = after,
      fields = 'id,name,is_viewer_admin,start_time',
    })
    for _,event in pairs(event_info.data) do
      local days_after = date.diff(right_now,date(event.start_time)):spandays()
      -- events in the future will be negative, events in the past
      -- will be positive. So we want < (some-time)
      if event.is_viewer_admin == true and days_after < 15 then -- skip events > 15 days old
        targets[event.id] = {
          type = 'event',
          name = event.name,
          token = access_token,
        }
      end
    end
  until event_info_err or event_info.paging == nil or event_info.paging.next == nil

  local page_info, page_info_err
  repeat
    local after
    if page_info and page_info.paging and page_info.paging.cursors then
        after = page_info.paging.cursors.after
    end
    page_info, page_info_err = fb_client:get('/me/accounts', {
      after = after
    })
    for _,page in pairs(page_info.data) do
      targets[page.id] = {
        type = 'page',
        name = page.name,
        token = page.access_token,
      }
    end
  until page_info_err or page_info.paging == nil or page_info.paging.next == nil

  return targets
end

function M.register_oauth(params)
  local user, _ = decode_with_secret(decode_base64(params.state))

  if not user then
    return false, 'error'
  end

  if not params.code then
    return false, 'error'
  end

  local httpc = http.new(http_error_handler)

  local token_res, token_err = httpc:get(graph_root .. '/oauth/access_token',
    {
      client_id = facebook_config.app_id,
      redirect_uri = M.redirect_uri,
      client_secret = facebook_config.app_secret,
      code = params.code,
    }
  )

  if token_err then return false, nil, token_err end

  local creds = from_json(token_res.body)

  -- then, echange the short-lived token for a long-lived token
  local long_token_res, long_token_err = httpc:get(graph_root .. '/oauth/access_token',
  {
    grant_type = 'fb_exchange_token',
    client_id = facebook_config.app_id,
    client_secret = facebook_config.app_secret,
    fb_exchange_token = creds.access_token,
  })

  if long_token_err then return false, nil, long_token_err end

  creds = from_json(long_token_res.body)

  if not creds.expires_in then
    local exp_res, exp_err = httpc:get(graph_root .. '/debug_token',
    {
      input_token = creds.access_token,
      access_token = facebook_config.app_id .. '|' .. facebook_config.app_secret,
    })
    if exp_err then
      ngx_log(ngx_debug,exp_err)
    end

    if exp_res and exp_res.status == 200 then
      ngx_log(ngx_debug,exp_res.body)
      local info = from_json(exp_res.body)

      -- check if this is a non-expiring token
      if info.data.expires_at == 0 and info.data.valid == true then
        creds.expires_in = 0
      else
        creds.expires_in = date.diff(date(info.data.expires_at),date(true)):spanseconds()
      end
    end
  else
    creds.expires_in = tonumber(creds.expires_in)
  end

  -- now, we can make the facebook client object

  local fb_client = facebook_client(creds.access_token)

  local user_info, err = fb_client:get('/me')
  if err then return false, nil, err end

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
      slug = slugify(user_info.name),
    })
  end

  if(creds.expires_in > 0) then
    account:set('access_token',creds.access_token, tonumber(creds.expires_in))
  else
    account:set('access_token',creds.access_token)
  end

  local available_targets = refresh_targets(creds.access_token)
  account:set('targets',to_json(available_targets))

  if account.user_id ~= user.id then
    return false, nil, "Account already registered"
  end

  local sa = nil

  if user.stream_id then
    sa = StreamAccount:find({ account_id = account.id, stream_id = user.stream_id })
    if not sa then
      sa = StreamAccount:create({ account_id = account.id, stream_id = user.stream_id })
    end
  end

  return account, sa, nil

end

function M.metadata_form(account, stream)
  local form = M.metadata_fields()
  local targets
  local targets_raw = account:get('targets')
  if not targets_raw then
    targets = refresh_targets(account:get('access_token'))
    account:set('targets',to_json(targets))
  else
    targets = from_json(targets_raw)
  end
  local keys = {}
  for k in pairs(targets) do insert(keys,k) end
  sort(keys,function(a,b)
    local a_type = targets[a].type
    local b_type = targets[b].type

    if a_type ~= b_type then
      if a_type == 'profile' then
        return true
      elseif a_type == 'page' and b_type ~= 'profile' then
        return true
      elseif a_type == 'event' and b_type ~= 'page' and b_type ~= 'profile' then
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
    elseif acc_type == 'group' then
      name = name .. ' (Group)'
    elseif acc_type == 'event' then
      name = name .. ' (Event)'
    end
    insert(form[3].options,
      { value = k,
        label = name,
      }
    )
  end

  for i,v in pairs(form) do
    v.value = stream:get(v.key)
    if v.type == 'checkbox' then
      if v.value == 'true' then
        v.value = true
      elseif v.value == 'false' then
        v.value = false
      else
        v.value = nil
      end

      -- nil means never set, default to 'true' for delete event
      if i == 7 and v.value == nil then
        v.value = true
      end
    end
  end

  if form[3].value ~= nil then
    -- fetch events!
    local fb_client = facebook_client(targets[form[3].value].token)
    local live_vids, _ = fb_client:get('/' .. form[3].value .. '/live_videos',
      { fields = 'status,stream_url,title,id,description,planned_start_time',
        limit = 10 })
    if live_vids then
      for _,vid in pairs(live_vids.data) do
        if not vid.title then
          vid.title = vid.description
        end
        if vid.planned_start_time then
          vid.title = format('%s (%s)',vid.title,vid.planned_start_time)
        elseif vid.status == 'LIVE' then
          vid.title = format('%s (LIVE)',vid.title)
        end
        if vid.status ~= 'VOD' and vid.status ~= 'PROCESSING' then
          insert(form[6].options,
            { label = vid.title,
              value = vid.id })
        end
      end
    end
  else
    form[6].options = {
      { label = 'Choose a profile/page, then refresh',
        value = 0} }
    form[6].value = 0
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
    },
    [6] = {
      type = 'select',
      label = 'Use Existing Event/Video',
      key = 'event',
      required = false,
      options = {
        { value = 0, label = 'Create new event/video' }
      },
    },
    [7] = {
      type = 'checkbox',
      label = 'End live video when stream ends',
      key = 'endlive',
      required = true,
    },
  }

end

function M.publish_start(account, stream)
  local stream_o = stream
  account = account:get_all()
  stream = stream:get_all()

  local fields = M.metadata_fields()
  for _,f in ipairs(fields) do
    if f.required == true then
      if not stream[f.key] or len(stream[f.key]) == 0 then
        return false, 'Facebook: missing field "' .. f.label ..'"'
      end
    end
  end

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
  params.fields = 'id,permalink_url,stream_url,status,is_manual_mode'

  local fb_client = facebook_client(access_token)
  local vid_info, vid_err

  if stream.event == nil or stream.event == '0' then
    vid_info, vid_err = fb_client:post('/'..stream.target..'/live_videos',params)
  else
    vid_info, vid_err = fb_client:get('/' .. stream.event, {
      fields = params.fields})
  end

  if vid_err then
    return false, vid_err
  end

  stream_o:set('http_url','https://facebook.com' .. vid_info.permalink_url)
  stream_o:set('video_id',vid_info.id)
  stream_o:set('rtmp_url',vid_info.stream_url)

  return vid_info.stream_url, nil
end

function M.publish_stop(account, stream)
  local stream_o = stream

  account = account:get_all()
  stream = stream:get_all()

  stream_o:unset('http_url')
  stream_o:unset('video_id')
  stream_o:unset('rtmp_url')

  if stream.endlive == 'false' or stream.endlive == false then
    return true
  end

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
    return 'Account needs refresh, re-add account'
  end

  if exp and exp < 864000 then -- if token expires in <10 days
    local httpc = http.new(http_error_handler)

    -- httpc.get = function(self,endpoint,params,headers)
    local res, err = httpc:get(graph_root .. '/oauth/client_code',
      {
        access_token = token,
        client_id = facebook_config.app_id,
        client_secret = facebook_config.app_secret,
        redirect_uri = M.redirect_uri,
      })

    if err then return 'Token expiring soon, but unable to refresh: ' .. err end

    local code = from_json(res.body).code

    res, err = httpc:get(graph_root .. '/oauth/access_token',
      {
        code = code,
        client_id = facebook_config.app_id,
        redirect_uri = M.redirect_uri,
      })

    if err then return 'Token expiring soon, but unable to refresh: ' .. err end

    local creds = from_json(res.body)
    account:set('access_token',creds.access_token, tonumber(creds.expires_in))
  end

  return false
end

function M.notify_update(_,_)
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
  ['PRIDE'] = 'is proud of this',
}

local function textify(emote)
  local text = emotes[emote]
  if not text then
    text = 'hit some kind of new reaction button that I don\'t know about'
  end
  return text
end

function M.create_viewcount_func(account,stream,send)
  if not send then return nil end

  local viewcount_func, stop_viewcount_func

  local targets = from_json(account.targets)
  local target = targets[stream.target]
  local access_token = target.token

  local video_id = stream.video_id
  local fb_client = facebook_client(access_token)

  local viewRunning = true
  viewcount_func = function()
    while viewRunning do
      local res, err = fb_client:get('/' .. video_id, {
        fields = 'id,live_views' })

      if not err then
        local viewer_count = tonumber(res.live_views)
        if not viewer_count then viewer_count = 0 end
        send({viewer_count = viewer_count})
      end
      ngx.sleep(60)
    end
    return true
  end

  stop_viewcount_func = function()
    viewRunning = false
  end

  return viewcount_func, stop_viewcount_func

end

function M.create_comment_funcs(account, stream, send)
  local targets = from_json(account.targets)
  local target = targets[stream.target]
  local access_token = target.token

  local video_id = stream.video_id
  local fb_client = facebook_client(access_token)
  local read_func, stop_func

  if send then
    local afterComment = nil
    local afterReaction = nil
    local readRunning = true
    local reactions = {}
    read_func = function()
      while readRunning do -- {{{
        local res, _ = fb_client:batch({
          {
            method = 'GET',
            relative_url = video_id .. '/comments?' ..
              encode_query_string({
                fields = 'created_time,from{name,id,picture},message,id',
                after = afterComment,
                live_filter = 'no_filter'
              }),
          },
          {
            method = 'GET',
            relative_url = video_id .. '/reactions?' ..
              encode_query_string({
                fields = 'id,name,type,picture',
                after = afterReaction
              }),
          }
        })
        if res[1].code == 200 then
          local body = from_json(res[1].body)
          if body.paging then afterComment = body.paging.cursors.after end
          for _,v in pairs(body.data) do
            send({
              type = 'text',
              from = {
                name = v.from.name,
                id = v.from.id,
                picture = v.from.picture.data.url,
              },
              text = v.message,
              markdown = escape_markdown(v.message),
            })
          end
        end
        if res[2].code == 200 then
          local body = from_json(res[2].body)
          if body.paging and body.paging.next then
              afterReaction = body.paging.cursors.after
          end
          for _,v in pairs(body.data) do
            if not reactions[v.id] then
              reactions[v.id] = true
              send({
                type = 'emote',
                from = {
                  name = v.name,
                  id = v.id,
                  picture = v.picture.data.url,
                },
                text = textify(v.type),
                markdown = escape_markdown(textify(v.type)),
              })
            end
          end
        end
        ngx.sleep(6)
      end -- }}}
      return true
    end
    stop_func = function()
      readRunning = false
    end
  end

  local write_func = nil

  return read_func, write_func, stop_func
end


return M
