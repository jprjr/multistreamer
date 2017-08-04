-- luacheck: globals ngx
local ngx = ngx

local Account = require'models.account'
local StreamAccount = require'models.stream_account'
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
local string = require'multistreamer.string'
local date = require'date'
local escape_markdown = string.escape_markdown
local split = string.split

local insert = table.insert
local concat = table.concat
local sort = table.sort
local pairs = pairs
local ipairs = ipairs
local ceil = math.ceil
local len = string.len
local tonumber = tonumber

local M = {}

M.name = 'youtube'
M.displayname = 'YouTube'
M.allow_sharing = true
M.read_comments = true
M.write_comments = true
M.redirect_uri = config.public_http_url .. config.http_prefix .. '/auth/youtube'

M.icon =
  '<svg viewBox="0 0 16 16" xmlns="http://www.w3.o' ..
  'rg/2000/svg" fill-rule="evenodd" clip-rule="evenodd" stroke-linejoin="ro' ..
  'und" stroke-miterlimit="1.414"><path d="M0 7.345c0-1.294.16-2.59.16-2.59' ..
  's.156-1.1.636-1.587c.608-.637 1.408-.617 1.764-.684C3.84 2.36 8 2.324 8 ' ..
  '2.324s3.362.004 5.6.166c.314.038.996.04 1.604.678.48.486.636 1.588.636 1' ..
  '.588S16 6.05 16 7.346v1.258c0 1.296-.16 2.59-.16 2.59s-.156 1.102-.636 1' ..
  '.588c-.608.638-1.29.64-1.604.678-2.238.162-5.6.166-5.6.166s-4.16-.037-5.' ..
  '44-.16c-.356-.067-1.156-.047-1.764-.684-.48-.487-.636-1.587-.636-1.587S0' ..
  ' 9.9 0 8.605v-1.26zm6.348 2.73V5.58l4.323 2.255-4.32 2.24z"/></svg>'


local function http_error_handler(res)
  return from_json(res.body).error.message
end

local function google_client(base_url,access_token)
  if not access_token then
    return false,'access_token required'
  end

  local httpc = http.new(http_error_handler)
  local _request = httpc.request

  local httpc_overrides = {}

  httpc_overrides.request = function(self,method,endpoint,params,headers,body)
    local url = base_url .. endpoint
    local req_headers = {
      ['Authorization'] = 'Bearer ' .. access_token,
    }
    if headers then
      for k,v in pairs(headers) do
          req_headers[k] = v
      end
    end

    local res, err = _request(self,method,url,params,req_headers,body)
    if err then return nil, err end
    return from_json(res.body)
  end

  httpc_overrides.get = function(self,endpoint,params,headers)
    return httpc_overrides.request(self,'GET',endpoint,params,headers)
  end

  httpc_overrides.post = function(self,endpoint,params,headers)
    headers = headers or {}
    headers['Content-Type'] = 'application/x-www-form-urlencoded'
    return httpc_overrides.request(self,'POST',endpoint,nil,headers,encode_query_string(params))
  end

  httpc_overrides.postJSON = function(self,endpoint,params,obj)
    local headers = {
      ['Content-Type'] = 'application/json'
    }
    obj = obj and to_json(obj) or ''
    return httpc_overrides.request(self,'POST',endpoint,params,headers,obj)
  end

  httpc_overrides.putJSON = function(self,endpoint,params,obj)
    local headers = {
      ['Content-Type'] = 'application/json'
    }
    obj = obj and to_json(obj) or ''
    return httpc_overrides.request(self,'PUT',endpoint,params,headers,obj)
  end

  httpc_overrides.__index = httpc_overrides
  setmetatable(httpc,httpc_overrides)

  return httpc, nil
end

local function youtube_client(access_token)
  return google_client('https://www.googleapis.com/youtube/v3',access_token)
end

local function refresh_access_token(refresh_token, access_token, expires_in, expires_at)
  local do_refresh = false
  local now = date(true)

  if not access_token then
    do_refresh = true
  else
    local expires_at_dt = date(expires_at)
    if now > expires_at_dt then
      do_refresh = true
    end
  end

  if do_refresh == true then

    local httpc = http.new(http_error_handler)
    local refresh_res, refresh_err = httpc:post('https://accounts.google.com/o/oauth2/token',
      nil,
      {
        ['Content-Type'] = 'application/x-www-form-urlencoded',
      },
      encode_query_string({
        client_id = config.networks[M.name].client_id,
        client_secret = config.networks[M.name].client_secret,
        refresh_token = refresh_token,
        grant_type = 'refresh_token',
      })
    )

    if refresh_err then return nil, refresh_err end

    local creds = from_json(refresh_res.body)

    return creds.access_token, creds.expires_in, now:addseconds(tonumber(creds.expires_in))
  else
    return access_token, expires_in, expires_at
  end
end

local function refresh_access_token_wrapper(account)
  local refresh_token = account['refresh_token']

  local access_token = account['access_token']
  local expires_in
  local expires_at

  if not access_token then
    access_token, expires_in, expires_at = refresh_access_token(refresh_token)
  else
    expires_in = account['access_token.expires_in']
    expires_at = account['access_token.expires_at']
  end

  return access_token, expires_in, expires_at
end

local function refresh_events(access_token)
  local nextPageToken = nil
  local getting_events = true
  local events = {}
  local yt = youtube_client(access_token)

  while getting_events do
    local live_broadcasts, err = yt:get('/liveBroadcasts', {
      part = 'id,snippet',
      broadcastStatus = 'upcoming',
      broadcastType = 'event',
      pageToken = nextPageToken,
    })
    if err then
      getting_events = false
    end
    if live_broadcasts and live_broadcasts.nextPageToken then
      nextPageToken = live_broadcasts.nextPageToken
    else
      getting_events = false
    end
    if live_broadcasts and live_broadcasts.items then
      for _,v in ipairs(live_broadcasts.items) do
        insert(events, {
          id = v.id,
          title = v.snippet.title,
          start = v.snippet.scheduledStartTime
        })
      end
    end
  end

  return events

end

function M.get_oauth_url(user,stream_id)
  return 'https://accounts.google.com/o/oauth2/auth?' ..
    encode_query_string({
      state = encode_base64(encode_with_secret({ id = user.id, stream_id = stream_id })),
      redirect_uri = M.redirect_uri,
      client_id = config.networks[M.name].client_id,
      scope = concat({
        'https://www.googleapis.com/auth/youtube.force-ssl',
        'https://www.googleapis.com/auth/youtube.upload',
        'https://www.googleapis.com/auth/userinfo.email',
      },' '),
      response_type = 'code',
      approval_prompt = 'force',
      access_type = 'offline',
    })
end

function M.register_oauth(params)
  local user, _ = decode_with_secret(decode_base64(params.state))

  if not user then
    return false, nil, 'YouTube error: no user info sent'
  end

  if not params.code then
    return false, nil, 'YouTube error: no temporary token'
  end

  local httpc = http.new(http_error_handler)
  local token_res, token_err = httpc:post('https://accounts.google.com/o/oauth2/token',
    nil,
    {
      ['Content-Type'] = 'application/x-www-form-urlencoded',
    },
    encode_query_string({
      client_id = config.networks[M.name].client_id,
      client_secret = config.networks[M.name].client_secret,
      redirect_uri = M.redirect_uri,
      code = params.code,
      grant_type = 'authorization_code',
    })
  )

  if token_err then return false, nil, token_err end

  local creds = from_json(token_res.body)

  local access_token = creds.access_token
  local exp = creds.expires_in
  local refresh_token = creds.refresh_token

  local yt = youtube_client(access_token)

  -- first get user info
  local user_res, user_err = yt:get('/channels', {
    part = 'snippet',
    mine = 'true',})

  if user_err then
    return false, nil, user_err
  end

  local user_id = user_res.items[1].id
  local name = user_res.items[1].snippet.title

  -- see if we have an account
  local sha1 = resty_sha1:new()
  sha1:update(user_id)
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
      name = name,
      slug = slugify(name),
    })
  end

  account:set('access_token',access_token,exp)
  account:set('refresh_token',refresh_token)

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
  M.check_errors(account)

  local form = M.metadata_fields()
  form[7].options = {}
  form[8].options = {
    [1] = {
      label = 'None',
      value = '',
    }
  }

  local access_token = account:get('access_token')

  local yt, err = youtube_client(access_token)
  if not yt then return false, err end
  local category_res, category_err = yt:get('/videoCategories', {
    part = 'snippet',
    regionCode = config.networks[M.name].country,
  })

  if not category_err then
    sort(category_res.items, function(a,b)
      return a.snippet.title < b.snippet.title
    end)

    for _,v in ipairs(category_res.items) do
      if v.snippet.assignable then
        insert(form[7].options, {
          label = v.snippet.title,
          value = v.id,
        })
      end
    end
  end

  local events = refresh_events(access_token)

  for _,v in ipairs(events) do
    insert(form[8].options, {
      label = v.title .. ' (' .. v.start .. ')',
      value = v.id,
    })
  end

  for _,v in pairs(form) do
    v.value = stream:get(v.key)
  end

  return form

end

function M.metadata_fields()
  local fields = {
    [1] = {
      type = 'text',
      label = 'Title',
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
      type = 'textarea',
      label = 'Tags (one per line)',
      key = 'tags',
      required = false,
    },
    [4] = {
      type = 'select',
      label = 'Privacy',
      key = 'privacy',
      required = true,
      options = {
        { label = 'Private', value = 'private' },
        { label = 'Unlisted', value = 'unlisted' },
        { label = 'Public', value = 'public' },
      },
    },
    [5] = {
      type = 'select',
      label = 'Resolution',
      key = 'resolution',
      required = true,
      options = {
        { label = '1440p', value = '1440p' },
        { label = '1080p', value = '1080p' },
        { label = '720p', value = '720p' },
        { label = '480p', value = '480p' },
        { label = '360p', value = '360p' },
        { label = '240p', value = '240p' },
      },
    },
    [6] = {
      type = 'select',
      label = 'Framerate',
      key = 'framerate',
      required = true,
      options = {
        { label = '30fps', value = '30fps' },
        { label = '60fps', value = '60fps' },
      },
    },
    [7] = {
      type = 'select',
      label = 'Category',
      key = 'category',
      required = true,
    },
    [8] = {
      type = 'select',
      label = 'Use pre-existing event (ignores most metadata)',
      key = 'event',
      required = false,
    },
    [9] = {
      type = 'checkbox',
      label = 'Enable low-latency',
      key = 'lowlatency',
      required = false,
    },
  }

  return fields

end

function M.publish_start(account, stream)
  local err = M.check_errors(account)
  if err then return false, err end

  local stream_o = stream

  account = account:get_all()
  stream = stream:get_all()

  local access_token = account.access_token

  local fields = M.metadata_fields()
  for _,f in ipairs(fields) do
    if f.required == true then
      if not stream[f.key] or len(stream[f.key]) == 0 then
        return false, 'YouTube: missing field "' .. f.label ..'"'
      end
    end
  end

  local title = stream.title
  local category = stream.category
  local privacy = stream.privacy
  local description = stream.description
  local resolution = stream.resolution
  local framerate = stream.framerate
  local event = stream.event
  local lowlatency = stream.lowlatency and true or nil
  local tags
  if stream.tags and len(stream.tags) > 0 then
    tags = split(stream.tags,'\r?\n')
  end

  -- the process:
  -- create Broadcast (POST /liveBroadcasts)
  -- create stream    (POST /liveStreams)
  -- create binding   (POST /liveBroadcasts/bind)
  -- update video metadata
  -- then after the video has started:
  -- transition broadcast to live (POST /liveBroadcasts/transition)

  local yt = youtube_client(access_token)

  local broadcast, broadcast_err
  if event then
    -- update broadcast to disable monitor stream
    local temp_bcast, temp_bcast_err = yt:get('/liveBroadcasts', {
      part = 'id,snippet,contentDetails,status',
      id = event,
    })
    if not temp_bcast_err then
      temp_bcast = temp_bcast.items[1]
      temp_bcast.contentDetails.monitorStream.enableMonitorStream = false
      broadcast, broadcast_err = yt:putJSON('/liveBroadcasts', {
        part = 'id,snippet,contentDetails,status',
      }, temp_bcast)
    else
      return temp_bcast_err
    end
  else
    broadcast, broadcast_err = yt:postJSON('/liveBroadcasts', {
      part = 'id,snippet,contentDetails,status',
    }, {
      snippet = {
        title = title,
        description = description,
        scheduledStartTime = date(true):fmt('${iso}') .. 'Z',
      },
      status = {
        privacyStatus = privacy,
      },
      contentDetails = {
        monitorStream = {
          enableMonitorStream = false,
          enableEmbed = true,
        },
        enableLowLatency = lowlatency,
      },
    })
  end

  if broadcast_err then
    return false, broadcast_err
  end

  local video_stream, video_err = yt:postJSON('/liveStreams', {
    part = 'id,snippet,cdn,status',
  }, {
    snippet = {
      title = title,
      description = description,
    },
    cdn = {
      ingestionType = 'rtmp',
      frameRate = framerate,
      resolution = resolution,
    },
  })

  if video_err then
    return false, video_err
  end

  local _, bind_err = yt:postJSON('/liveBroadcasts/bind', {
    part = 'id,snippet,contentDetails,status',
    id = broadcast.id,
    streamId = video_stream.id,
  })

  if bind_err then
    return false, bind_err
  end

  if not event then
    local _, update_err = yt:putJSON('/videos', {
      part = 'id,snippet',}, {
      id = broadcast.id,
      snippet = {
        title = title,
        description = description,
        categoryId = category,
        tags = tags,
      }
    })

    if update_err then
      return false, update_err
    end
  end

  local http_url = 'https://youtu.be/' .. broadcast.id

  stream_o:set('http_url',http_url)
  stream_o:set('broadcast_id',broadcast.id)
  stream_o:set('chat_id',broadcast.snippet.liveChatId)
  stream_o:set('stream_id',video_stream.id)
  stream_o:set('stream_status',video_stream.status.streamStatus)

  local rtmp_url = video_stream.cdn.ingestionInfo.ingestionAddress .. '/' .. video_stream.cdn.ingestionInfo.streamName

  return rtmp_url, nil
end

function M.notify_update(account, stream)
  local err = M.check_errors(account)
  if err then return false, err end
  local stream_o = stream

  account = account:get_all()
  stream = stream:get_all()

  if stream.stream_status == 'active' then
    return true, nil
  end

  local access_token = account.access_token
  local broadcast_id = stream.broadcast_id
  local stream_id    = stream.stream_id

  local yt = youtube_client(access_token)

  local stream_info, stream_info_err = yt:get('/liveStreams', {
    id = stream_id,
    part = 'id,status',
  })

  if stream_info_err then
    return false, stream_info_err
  end

  if stream_info.items[1].status.streamStatus == 'active' then
    yt:postJSON('/liveBroadcasts/transition', {
      id = broadcast_id,
      broadcastStatus = 'live',
      part = 'status',
    })
    stream_o:set('stream_status','active')
  end
  return true, nil
end

function M.publish_stop(account, stream)
  local err = M.check_errors(account)
  if err then return false, err end
  local stream_o = stream

  account = account:get_all()
  stream = stream:get_all()

  stream_o:unset('http_url')
  stream_o:unset('broadcast_id')
  stream_o:unset('stream_id')
  stream_o:unset('chat_id')
  stream_o:unset('stream_status')

  local access_token = account.access_token

  local broadcast_id = stream.broadcast_id

  local yt = youtube_client(access_token)

  yt:postJSON('/liveBroadcasts/transition', {
    id = broadcast_id,
    broadcastStatus = 'complete',
    part = 'status',
  })

  return true
end


function M.check_errors(account)
  local access_token, exp, _
  access_token, _ = account:get('access_token')
  if access_token then
    return false, nil
  end

  local refresh_token = account:get('refresh_token')
  access_token, exp = refresh_access_token(refresh_token)

  if not access_token then
    return exp
  end

  account:set('access_token',access_token,exp)

  return false,nil
end

function M.create_viewcount_func(account,stream,send)
  local refresh_token = account['refresh_token']

  local access_token, expires_in, expires_at = refresh_access_token_wrapper(account)

  if not send then
    return nil
  end

  local viewcount_func, stop_viewcount_func
  local viewRunning = true

  viewcount_func = function()
    while viewRunning do
      access_token, expires_in, expires_at = refresh_access_token(refresh_token, access_token, expires_in, expires_at)
      if access_token then
        local yt = youtube_client(access_token)
        local res, _ = yt:get('/videos',{
          part = 'id,liveStreamingDetails',
          id = stream['broadcast_id']
        })
        if res then
          local viewer_count = tonumber(res.items[1].liveStreamingDetails.concurrentViewers)
          if not viewer_count then
            viewer_count = 0
          end
          send({viewer_count = viewer_count})
        end
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
  local read_func = nil
  local stop_func = nil

  local refresh_token = account['refresh_token']

  local access_token, expires_in, expires_at = refresh_access_token_wrapper(account)

  if send then
    local nextPageToken = nil
    local readRunning = true
    read_func = function()
      while readRunning do
        local sleeptime = 6
        access_token, expires_in, expires_at = refresh_access_token(refresh_token, access_token, expires_in, expires_at)
        if access_token then
          local yt = youtube_client(access_token)
          local res, _ = yt:get('/liveChat/messages',{
            liveChatId = stream.chat_id,
            part = 'id,snippet,authorDetails',
            pageToken = nextPageToken,
          })
          if res then
            if res.nextPageToken then nextPageToken = res.nextPageToken end
            for _,v in ipairs(res.items) do
              send({
                type = 'text',
                from = {
                  name = v.authorDetails.displayName,
                  id = v.authorDetails.channelId,
                  picture = v.authorDetails.profileImageUrl,
                },
                text = v.snippet.textMessageDetails.messageText,
                markdown = escape_markdown(v.snippet.textMessageDetails.messageText)
              })
            end
            sleeptime = ceil(res.pollingIntervalMillis/1000)
          end
        end
        ngx.sleep(sleeptime)
      end
      return true
    end
    stop_func = function()
      readRunning = false
    end
  end

  local write_func = function(message)
    access_token, expires_in, expires_at = refresh_access_token(refresh_token, access_token, expires_in, expires_at)
    local err, _
    err = ''
    if access_token then
      local yt = youtube_client(access_token)

      if message.type == 'emote' then
        message.text = '*'..message.text..'*'
      end

      _, err = yt:postJSON('/liveChat/messages',{
        part = 'snippet',
        liveChatId = stream.chat_id,
      }, {
        snippet = {
          liveChatId = stream.chat_id,
          type = 'textMessageEvent',
          textMessageDetails = {
            messageText = message.text,
          },
        }
      })
      if err then
        return false, err
      end
      return true, nil
    end
    return false, err
  end

  return read_func, write_func, stop_func
end

return M
