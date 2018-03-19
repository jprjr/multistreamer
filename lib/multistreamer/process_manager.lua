-- luacheck: globals ngx bash_path lua_bin
local ngx = ngx
local lua_bin = lua_bin

local config = require'multistreamer.config'.get()
local redis = require'multistreamer.redis'
local endpoint = redis.endpoint
local subscribe = redis.subscribe
local from_json = require('lapis.util').from_json
local to_json = require('lapis.util').to_json
local Stream = require'multistreamer.models.stream'
local shell = require'multistreamer.shell'
local setmetatable = setmetatable
local tonumber = tonumber
local pairs = pairs
local insert = insert or table.insert --luacheck: compat
local concat = table.concat

local exec_socket = require'resty.exec.socket'

local ngx_err = ngx.ERR
local ngx_error = ngx.ERROR
local ngx_debug = ngx.DEBUG
local ngx_log = ngx.log
local ngx_exit = ngx.exit
local ngx_sleep = ngx.sleep

local pid = ngx.worker.pid()
local spawn = ngx.thread.spawn
local streams_dict = ngx.shared.streams
local status_dict = ngx.shared.status

local function start_process(callback,self,process_args,pusher,stream_id,account_id)
  return function()
    local running = true
    local attempts = 0
    while running do
      local client = exec_socket:new({ timeout = 300000 }) -- 5 minutes
      local ok = client:connect(config.sockexec_path)
      if not ok then
        ngx_log(ngx_err,'[Process Manager] Unable to connect to sockexec!')
        status_dict:set('processmgr_error', true)
        return
      end
      if pusher then -- always start new connection when pushing
        self.pushers[stream_id][account_id] = client
      else
        self.pullers[stream_id] = client
      end
      ngx_log(ngx_debug,'[Process Manager] Starting: ' .. concat(process_args, ' '))
      client:send_args(process_args)
      client:send_close()
      local data, typ, err, errr
      ok = true
      while(not err) do
        data, typ, err= client:receive()
        if err and err == 'timeout' then
          err = nil
        end
        if typ == 'termsig' then
          ngx_log(ngx_err,'[Process Manager] Process ended with signal ' .. data)
          ok = false
          errr = 'signal: ' .. data
        elseif typ == 'exitcode' then
          if tonumber(data) > 0 then
            ngx_log(ngx_err,'[Process Manager] Process ended with error exit code: ' .. data)
            ok = false
            errr = 'exitcode: ' .. data
          else
            ngx_log(ngx_debug,'[Process Manager] Process ended with normal exit code: ' .. data)
          end
        elseif typ == 'stdout' then
          ngx_log(ngx_err,'[Process Manager] stdout: ' .. data)
        elseif typ == 'stderr' then
          ngx_log(ngx_err,'[Process Manager] stdout: ' .. data)
        end
      end

      if pusher then
        ngx_sleep(2)
        local stream_status = streams_dict:get(stream_id)
        if stream_status then
          stream_status = from_json(stream_status)
        else
          stream_status = {
            data_pushing = false,
            data_incoming = false,
            data_pulling = true,
          }
        end
        if stream_status.data_pushing == false then
          running = false
        else
          attempts = attempts +  1
          if attempts >= config.ffmpeg_max_attempts then
            ngx_log(ngx_err,'[Process Manager] Reached ffmpeg attempt limit -- giving up')
            running = false
          end
        end
      else
        running = false
      end
    end

    if callback then
      callback()
    end
    return ok, errr
  end
end


local ProcessMgr = {}
ProcessMgr.__index = ProcessMgr

ProcessMgr.new = function()
  local t = {}
  t.pushers = {}
  t.pullers = {}
  t.messageFuncs = {
    [endpoint('process:start:push')] = ProcessMgr.startPush,
    [endpoint('process:start:repush')] = ProcessMgr.startRePush,
    [endpoint('process:end:push')] = ProcessMgr.endPush,
    [endpoint('process:start:pull')] = ProcessMgr.startPull,
    [endpoint('process:end:pull')] = ProcessMgr.endPull,
  }
  setmetatable(t,ProcessMgr)
  return t
end

function ProcessMgr:run()
  local running = true
  local ok, red = subscribe('process:start:push')
  if not ok then
    ngx_log(ngx_err,'[Process Manager] Unable to connect to redis: ' .. red)
    status_dict:set('processmgr_error',true)
    ngx_exit(ngx_error)
  end
  subscribe('process:end:push',red)
  subscribe('process:start:pull',red)
  subscribe('process:end:pull',red)

  while(running) do
    local res, err = red:read_reply()
    if err and err ~= 'timeout' then
      ngx_log(ngx_err,'[Process Manager] Redis Disconnected!')
      ngx_exit(ngx_error)
    end
    if res then
      local func = self.messageFuncs[res[2]]
      if func then
        func(self,from_json(res[3]))
      end
    end
  end
end

function ProcessMgr:startPushInt(stream)
  local sas = stream:get_streams_accounts()

  ngx_log(ngx_debug,'[Process Manager] Starting pusher')

  for _,sa in pairs(sas) do
    local account = sa:get_account()

    local ffmpeg_args = {
      config.ffmpeg,
      '-v',
      'error',
      '-copyts',
      '-vsync',
      '0',
      '-rtmp_flashver',
      'accountid:' .. account.id,
      '-i',
      config.private_rtmp_url ..'/'.. config.rtmp_prefix ..'/'.. stream.uuid,
    }
    local args = {}

    if account.ffmpeg_args and len(account.ffmpeg_args) > 0 then
      args = shell.parse(account.ffmpeg_args)
    end

    if sa.ffmpeg_args and len(sa.ffmpeg_args) > 0 then
      args = shell.parse(sa.ffmpeg_args)
    end
    if #args == 0 then
      args = { '-c:v','copy','-c:a','copy' }
    end

    for _,v in pairs(args) do
      insert(ffmpeg_args,v)
    end

    insert(ffmpeg_args,'-muxdelay')
    insert(ffmpeg_args,'0')
    insert(ffmpeg_args,'-f')
    insert(ffmpeg_args,'flv')
    insert(ffmpeg_args,sa.rtmp_url)

    if(not self.pushers[stream.id][sa.account_id]) then
      spawn(start_process(function()
        self.pushers[stream.id][sa.account_id] = nil
      end,self,ffmpeg_args,true,stream.id,account.id))
    end
  end

  return true
end

function ProcessMgr:startRePush(msg)
  local stream = Stream:find({id = msg.id})

  if not stream then
    return nil
  end

  if not self.pushers[stream.id] then return nil end

  return self:startPushInt(stream)
end


function ProcessMgr:startPush(msg)
  if msg.worker ~= pid then
    return nil
  end

  local stream = Stream:find({id = msg.id})

  if not stream then
    return nil
  end

  if not self.pushers[stream.id] then
    self.pushers[stream.id] = {}
  end

  if msg.delay then
    ngx_sleep(msg.delay)
  end

  return self:startPushInt(stream)
end

function ProcessMgr:startPull(msg)
  if msg.worker ~= pid then
    return nil
  end

  local stream = Stream:find({id = msg.id})

  if not stream then
    return nil
  end

  local stream_status = streams_dict:get(stream.id)
  if stream_status then
    stream_status = from_json(stream_status)
  else
    stream_status = {
      data_pushing = false,
      data_incoming = false,
      data_pulling = true,
    }
  end
  stream_status.data_pulling = true
  streams_dict:set(stream.id,to_json(stream_status))

  local ffmpeg_args = {
    '-v',
    'error',
  }

  local args = shell.parse(stream.ffmpeg_pull_args)
  for _,v in pairs(args) do
    insert(ffmpeg_args,v)
  end

  insert(ffmpeg_args,'-f')
  insert(ffmpeg_args,'flv')
  insert(ffmpeg_args,config.private_rtmp_url ..'/'..config.rtmp_prefix..'/'..stream.uuid)

  spawn(start_process(function()
    local _stream_status = streams_dict:get(stream.id)
    if _stream_status then
      _stream_status = from_json(_stream_status)
    else
      _stream_status = {
        data_pushing = false,
        data_incoming = false,
        data_pulling = false,
      }
    end
    _stream_status.data_pulling = false
    streams_dict:set(stream.id,to_json(_stream_status))
    self.pullers[stream.id] = nil
  end,self,ffmpeg_args,false,stream.id))

  return true
end

function ProcessMgr:endPush(msg)
  if not msg.id then return end


  if not self.pushers[msg.id] then return end

  for _,account_id in ipairs(msg.accounts) do
    if self.pushers[msg.id][account_id] then
      self.pushers[msg.id][account_id]:close()
    end
  end

  return true
end

function ProcessMgr:endPull(msg)
  if not msg.id then return end

  if not self.pullers[msg.id] then return end

  self.pullers[msg.id]:send('q')
  return true
end

return ProcessMgr

