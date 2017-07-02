local ngx = ngx
local config = require'multistreamer.config'
local string = require'multistreamer.string'
local redis = require'multistreamer.redis'
local endpoint = redis.endpoint
local publish = redis.publish
local subscribe = redis.subscribe
local from_json = require('lapis.util').from_json
local to_json = require('lapis.util').to_json
local Stream = require'models.stream'
local Account = require'models.account'
local StreamAccount = require'models.stream_account'
local setmetatable = setmetatable
local insert = table.insert
local tonumber = tonumber
local pairs = pairs

local exec_socket = require'resty.exec.socket'

local ngx_err = ngx.ERR
local ngx_error = ngx.ERROR
local ngx_debug = ngx.DEBUG
local ngx_log = ngx.log
local ngx_exit = ngx.exit
local ngx_sleep = ngx.sleep

local pid = ngx.worker.pid()
local kill = ngx.thread.kill
local spawn = ngx.thread.spawn
local streams_dict = ngx.shared.streams
local status_dict = ngx.shared.status

local function start_process(callback,client,...)
  local args = {...}
  return function()
    client:send_args(args)
    local data, typ, err, ok, errr
    ok = true
    while(not err) do
      data, typ, err= client:receive()
      if err and err == 'timeout' then
        ngx_log(ngx_debug,'[Process Manager] timeout, looping')
        err = nil
      end
      if typ == nil then
        -- 'err' was timeout or closed
      elseif typ == 'termsig' then
        ngx_log(ngx_error,'[Process Manager] Process ended with signal ' .. data)
        ok = false
        errr = 'signal: ' .. data
      elseif typ == 'exitcode' then
        if tonumber(data) > 0 then
          ngx_log(ngx_err,'[Process Manager] Process ended with exit code: ' .. data)
          ok = false
          errr = 'exitcode: ' .. data
        else
          ngx_log(ngx_debug,'[Process Manager] Process ended normally')
        end
      elseif typ == 'stdout' then
        ngx_log(ngx_err,'[Process Manager] stdout: ' .. data)
      elseif typ == 'stderr' then
        ngx_log(ngx_err,'[Process Manager] stdout: ' .. data)
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

function ProcessMgr:startPush(msg)
  if msg.worker ~= pid then
    return nil
  end

  local stream = Stream:find({id = msg.id})

  if not stream then
    return nil
  end

  local sas = stream:get_streams_accounts()

  ngx_log(ngx_debug,'[Process Manager] Starting pusher')

  if not self.pushers[stream.id] then
    self.pushers[stream.id] = {}
  end

  for _,sa in pairs(sas) do
    local client = exec_socket:new({ timeout = 300000 }) -- 5 minutes
    local ok, err = client:connect(config.sockexec_path)
    if not ok then
      ngx_log(ngx_err,'[Process Manager] Unable to connect to sockexec!')
      status_dict:set('processmgr_error', true)
      return
    end

    self.pushers[stream.id][sa.account_id] = client

    spawn(start_process(function()
      self.pushers[stream.id][sa.account_id] = nil
    end,client,bash_path,'-l',lua_bin,'-e',os.getenv('LAPIS_ENVIRONMENT'),'push',stream.id,sa.account_id))
  end

  return true
end

function ProcessMgr:startPull(msg)
  if msg.worker ~= pid then
    return nil
  end

  local stream = Stream:find({id = msg.id})

  if not stream then
    return nil
  end

  local client = exec_socket:new({ timeout = 300000 }) -- 5 minutes
  local ok, err = client:connect(config.sockexec_path)
  if not ok then
    ngx_log(ngx_err,'[Process Manager] Unable to connect to sockexec!')
    status_dict:set('processmgr_error', true)
    return
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

  spawn(start_process(function()
    local stream_status = streams_dict:get(stream.id)
    if stream_status then
      stream_status = from_json(stream_status)
    else
      stream_status = {
        data_pushing = false,
        data_incoming = false,
        data_pulling = false,
      }
    end
    stream_status.data_pulling = false
    streams_dict:set(stream.id,to_json(stream_status))
    self.pullers[stream.id] = nil
  end,client,bash_path,'-l',lua_bin,'-e',os.getenv('LAPIS_ENVIRONMENT'),'pull',stream.id))
  self.pullers[stream.id] = client

  return true
end

function ProcessMgr:endPush(msg)
  if not msg.id then return end


  if not self.pushers[msg.id] then return end

  for _,account_id in ipairs(msg.accounts) do
    if self.pushers[msg.id][account_id] then
      local bytes, err = self.pushers[msg.id][account_id]:send('q')
      if not bytes then
        ngx_log(ngx_err,'[Process Manager] failed to send quit message: ' .. err)
      end
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
