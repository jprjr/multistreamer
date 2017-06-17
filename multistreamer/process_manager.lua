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

local exec = require'resty.exec'

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

local function log_result(res, typ)
  if not res or res.termsig ~= nil then
    ngx_log(ngx_err,'[Process Manager] ' .. typ .. ' ended unexpectedly unexpectedly - check sockexec timeout value')
    return
  end
  if res.exitcode ~= nil and res.exitcode > 0 then
    ngx_log(ngx_err,'[Process Manager] '..typ..' ended with non-zero exit code')
    if res.stderr then
      ngx_log(ngx_err,'[Process Manager] stderr: ' .. res.stderr)
    end
    if res.stdout then
      ngx_log(ngx_err,'[Process Manager] stdout: ' .. res.stdout)
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

  ngx_log(ngx_debug,'[Process Manager] Starting pusher')

  self.pushers[stream.id] = spawn(function()
    local prog = exec.new(config.sockexec_path)
    prog.timeout_fatal = false

    local running = true
    while running do
      local res = prog(bash_path,'-l',lua_bin,'-e',os.getenv('LAPIS_ENVIRONMENT'),'push',stream.uuid)

      ngx_log(ngx.NOTICE,'[Process Manager] Pusher ended')
      log_result(res,'Pusher')

      ngx_sleep(10)
      local stream_status = streams_dict:get(stream.id)
      if stream_status then
        stream_status = from_json(stream_status)
      else
        stream_status = {
          data_incoming = false,
          data_pushing = false,
          data_pulling = false,
        }
      end
      if stream_status.data_incoming == false then
        running = false
      end
    end
    
  end)

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

  self.pullers[stream.id] = spawn(function()
    local prog = exec.new(config.sockexec_path)
    prog.timeout_fatal = false
    local res = prog(bash_path,'-l',lua_bin,'-e',os.getenv('LAPIS_ENVIRONMENT'),'pull',stream.uuid)
    log_result(res,'Puller')

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
  end)

  return true
end

function ProcessMgr:endPush(msg)
  if not msg.id then return end

  if not self.pushers[msg.id] then return end

  kill(self.pushers[msg.id])

  return true
end

function ProcessMgr:endPull(msg)
  if not msg.id then return end

  if not self.pullers[msg.id] then return end

  kill(self.pullers[msg.id])
  return true
end

return ProcessMgr
