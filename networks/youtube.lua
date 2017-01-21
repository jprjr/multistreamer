local Account = require'models.account'
local config = require'helpers.config'
local encode_query_string = require('lapis.util').encode_query_string
local encode_base64 = require('lapis.util.encoding').encode_base64
local decode_base64 = require('lapis.util.encoding').decode_base64
local encode_with_secret = require('lapis.util.encoding').encode_with_secret
local decode_with_secret = require('lapis.util.encoding').decode_with_secret
local to_json   = require('lapis.util').to_json
local from_json = require('lapis.util').from_json
local slugify = require('lapis.util').slugify

local http = require'resty.http'
local resty_sha1 = require'resty.sha1'
local str = require'resty.string'
local date = require'date'

local insert = table.insert
local concat = table.concat
local sort = table.sort
local db = require'lapis.db'
local pairs = pairs
local ipairs = ipairs
local ceil = math.ceil
local len = string.len

local M = {}

M.displayname = 'YouTube'
M.allow_sharing = true

M.read_comments = true
M.write_comments = true

local api_uri = 'https://www.googleapis.com/youtube/v3'

local function google_client(base_url,access_token)
  if not access_token then
    return false,'access_token required'
  end

  local t = {}
  t.httpc = http.new()
  t.access_token = access_token

  t.request = function(self,method,endpoint,params,headers,body)
    local uri = base_url .. endpoint
    local req_headers = {
      ['Authorization'] = 'Bearer ' .. self.access_token,
    }
    if params then
      uri = uri .. '?' .. encode_query_string(params)
    end
    if headers then
      for k,v in pairs(headers) do
          req_headers[k] = v
      end
    end

    local res, err = self.httpc:request_uri(uri, {
      method = method,
      headers = req_headers,
      body = body,
    })
    if err then
      return false, err
    end

    if res.status >= 400 then
      return false, from_json(res.body)
    end

    return from_json(res.body), nil
  end

  t.get = function(self,endpoint,params,headers)
    return self:request('GET',endpoint,params,headers)
  end
  t.post = function(self,endpoint,params,headers)
    if not headers then headers = {} end
    headers['Content-Type'] = 'application/x-www-form-urlencoded'
    return self:request('POST',endpoint,nil,headers,encode_query_string(params))
  end
  t.postJSON = function(self,endpoint,qparams,params,headers)
    if not headers then headers = {} end
    headers['Content-Type'] = 'application/json'
    if params then params = to_json(params) else params = '' end
    return self:request('POST',endpoint,qparams,headers,params)
  end

  return t,nil

end

local function youtube_client(access_token)
  return google_client('https://www.googleapis.com/youtube/v3',access_token)
end

local function plus_client(access_token)
  return google_client('https://www.googleapis.com/plus/v1',access_token)
end


function M.get_oauth_url(user)
  return 'https://accounts.google.com/o/oauth2/auth?' ..
    encode_query_string({
      state = encode_base64(encode_with_secret({ id = user.id })),
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
  local user, err = decode_with_secret(decode_base64(params.state))

  if not user then
    return false, 'error'
  end

  if not params.code then
    return false, 'error'
  end

  local httpc = http.new()

  local res, err = httpc:request_uri('https://accounts.google.com/o/oauth2/token', {
    method = 'POST',
    body = encode_query_string({
      client_id = config.networks[M.name].client_id,
      client_secret = config.networks[M.name].client_secret,
      redirect_uri = M.redirect_uri,
      code = params.code,
      grant_type = 'authorization_code',
    }),
    headers = {
      ['Content-Type'] = 'application/x-www-form-urlencoded',
    },
  })

  if err then -- or res.status >= 400 then
    return false, err
  end
  if res.status >= 400 then
    return false, res.body
  end

  local creds = from_json(res.body)

  local access_token = creds.access_token
  local exp = creds.expires_in
  local refresh_token = creds.refresh_token

  local pc = plus_client(access_token)
  local yt = youtube_client(access_token)

  -- first get user info
  local res, err = yt:get('/channels', {
    part = 'snippet',
    mine = 'true',})
  local user_id = res.items[1].id
  local name = res.items[1].snippet.title

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
    return false, "Account already registered"
  end

  return account, nil

end

function M.metadata_form(account, stream)
  local form = M.metadata_fields()

  for i,v in pairs(form) do
    v.value = stream:get(v.key)
  end

  return form

end

function M.metadata_fields()
  return {
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
    [4] = {
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
    [5] = {
      type = 'select',
      label = 'Framerate',
      key = 'framerate',
      required = true,
      options = {
        { label = '30fps', value = '30fps' },
        { label = '60fps', value = '60fps' },
      },
    },
  }

end

function M.publish_start(account, stream)
  local err = M.check_errors(account)
  if err then return false, err end

  local stream_o = stream

  local account = account:get_all()
  local stream = stream:get_all()

  local access_token = account.access_token

  local title = stream.title
  local privacy = stream.privacy
  local description = stream.description
  local resolution = stream.resolution
  local framerate = stream.framerate

  -- the process:
  -- create Broadcast (POST /liveBroadcasts)
  -- create stream    (POST /liveStreams)
  -- create binding   (POST /liveBroadcasts/bind)
  -- then after the video has started:
  -- transition broadcast to live (POST /liveBroadcasts/transition)

  local yt = youtube_client(access_token)

  local broadcast, err = yt:postJSON('/liveBroadcasts', {
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
    },
  })

  if err then
    return false, to_json(err)
  end

  local video_stream, err = yt:postJSON('/liveStreams', {
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

  if err then
    return false, to_json(err)
  end

  local bind_res, err = yt:postJSON('/liveBroadcasts/bind', {
    part = 'id, snippet, contentDetails,status',
    id = broadcast.id,
    streamId = video_stream.id,
  })

  if err then
    return false, to_json(err)
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

  local account = account:get_all()
  local stream = stream:get_all()

  if stream.stream_status == 'active' then
    return true, nil
  end

  local access_token = account.access_token
  local broadcast_id = stream.broadcast_id
  local stream_id    = stream.stream_id

  local yt = youtube_client(access_token)

  local stream_info, err = yt:get('/liveStreams', {
    id = stream_id,
    part = 'status',
  })

  if err then
    return false, to_json(err)
  end

  if stream_info.items[1].status.streamStatus == 'active' then
    local live_res, err = yt:postJSON('/liveBroadcasts/transition', {
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

  local account = account:get_all()
  local stream = stream:get_all()

  stream_o:unset('http_url')
  stream_o:unset('broadcast_id')
  stream_o:unset('stream_id')
  stream_o:unset('chat_id')
  stream_o:unset('stream_status')

  local access_token = account.access_token

  local broadcast_id = stream.broadcast_id
  local stream_id = stream.stream_id

  local yt = youtube_client(access_token)

  local live_res, err = yt:postJSON('/liveBroadcasts/transition', {
    id = broadcast_id,
    broadcastStatus = 'complete',
    part = 'status',
  })

  return true
end

function M.check_errors(account)
  local account_token, exp = account:get('access_token')
  if account_token then
    return false, nil
  end

  local refresh_token = account:get('refresh_token')

  local httpc = http.new()
  local res, err = httpc:request_uri('https://accounts.google.com/o/oauth2/token', {
    method = 'POST',
    body = encode_query_string({
      client_id = config.networks[M.name].client_id,
      client_secret = config.networks[M.name].client_secret,
      refresh_token = refresh_token,
      grant_type = 'refresh_token',
    }),
    headers = {
      ['Content-Type'] = 'application/x-www-form-urlencoded',
    },
  })

  if err then
    return err
  end
  if res.status >= 400 then
    return res.body
  end

  local creds = from_json(res.body)

  account:set('access_token',creds.access_token,creds.expires_in)

  return false,nil
end

function M.create_comment_funcs(account, stream, send)
  local read_func = nil

  if send then
    read_func = function()
      local nextPageToken = nil
      while true do
        local err = M.check_errors(account)
        if not err then
          local yt = youtube_client(account:get('access_token'))
          local res, err = yt:get('/liveChat/messages',{
            liveChatId = stream.chat_id,
            part = 'id,snippet,authorDetails',
            pageToken = nextPageToken,
          })
          if res then
            if res.nextPageToken then nextPageToken = res.nextPageToken end
            for i,v in ipairs(res.items) do
              send({
                type = 'text',
                from = {
                  name = v.authorDetails.displayName,
                  id = v.authorDetails.channelId,
                },
                text = v.snippet.textMessageDetails.messageText,
              })
            end
          end
        end
        local sleep = ceil(res.pollingIntervalMillis/1000)
        if sleep < 6 then
          sleep = 6
        end
        ngx.sleep(sleep)
      end
    end
  end

  local write_func = function(text)
    local err = M.check_errors(account)
    if not err then
      local yt = youtube_client(account:get('access_token'))
      local res, err = yt:postJSON('/liveChat/messages',{
        part = 'snippet',
        liveChatId = stream.chat_id,
      }, {
        snippet = {
          liveChatId = stream.chat_id,
          type = 'textMessageEvent',
          textMessageDetails = {
            messageText = text,
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

  return read_func, write_func
end


return M
