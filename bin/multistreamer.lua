#!/usr/bin/env lua

local getenv = os.getenv
local multistreamer_env = getenv('LAPIS_ENVIRONMENT')
if not multistreamer_env then
  print('LAPIS_ENVIRONMENT not set')
  exit(1)
end

local posix = require'posix'
local len = string.len
local exit = os.exit
local etlua = require'etlua'
local insert = table.insert
local whereami = require'whereami'
local StreamModel = require'models.stream'

local script_path = posix.realpath(arg[0])
local streamer_dir = posix.dirname(posix.dirname(script_path))
posix.chdir(streamer_dir)


local commands = {
  ['run'] = 1,
  ['initdb'] = 1,
  ['psql'] = 1,
  ['push'] = 1, -- internal command
}

local sql_files = {
  [1] = streamer_dir .. '/sql/1477785578.sql',
}

if(not arg[1] or not commands[arg[1]]) then
  print('syntax: ' ..  script_path .. ' <action>')
  print('Available actions')
  print('  run    -- run nginx')
  print('  initdb -- initialize the database')
  print('  psql   -- launch psql')
  exit(1)
end


local config = require('lapis.config').get()

if not config.rtmp_prefix then
  config.rtmp_prefix = 'multistreamer'
end

if not config.http_prefix then
  print('error: no http_prefix set in config.lua')
  exit(1)
end
config.multistreamer_env = multistreamer_env

config.http_prefix = config.http_prefix:gsub('/+$','')
config.public_http_url = config.public_http_url:gsub('/+$','')
config.public_rtmp_url = config.public_rtmp_url:gsub('/+$','')
config.private_http_url = config.private_http_url:gsub('/+$','')
config.private_rtmp_url = config.private_rtmp_url:gsub('/+$','')


if(arg[1] == 'run') then
  local whereami = require'whereami'
  local lua_bin = whereami()
  local lfs = require'lfs'

  config.lua_bin = lua_bin
  config.script_path = script_path;

  if not config.work_dir then
    config.work_dir = getenv('HOME') .. '/.multistreamer'
  end

  if not lfs.attributes(config.work_dir) then
    lfs.mkdir(config.work_dir)
  end

  if not lfs.attributes(config.work_dir .. '/logs') then
    lfs.mkdir(config.work_dir .. '/logs')
  end

  if not config.http_listen then
     config.http_listen = '127.0.0.1:8080'
  end
  if not config.rtmp_listen then
     config.rtmp_listen = '127.0.0.1:1935'
  end

  if not config.worker_processes then
    config.worker_processes = 1
  end

  if not config.log_level then
    config.log_level = 'error'
  end

  config.streamer_dir = streamer_dir

  local nf = io.open(streamer_dir .. '/res/nginx.conf','rb')
  local nginx_config_template = nf:read('*all')
  nf:close()

  local template = etlua.compile(nginx_config_template)

  local nof = io.open(config.work_dir .. '/nginx.'..multistreamer_env..'.conf', 'wb')
  nof:write(template(config))
  nof:close()

  posix.exec(config.nginx, { '-p', config.work_dir, '-c', 'nginx.'..multistreamer_env..'.conf' })

elseif(arg[1] == 'psql') then
  posix.exec(config.psql, { '-U', config.postgres.user, '-h' , config.postgres.host })

elseif(arg[1] == 'initdb') then
  for i,f in ipairs(sql_files) do
    local pid, errmsg = posix.fork()
    if pid == nil then
      print(errmsg)
      exit(1)
    elseif pid == 0 then
      posix.exec(config.psql, { '-U', config.postgres.user, '-h' , config.postgres.host, '-f', f })
    else
      posix.wait(pid)
    end
  end

elseif(arg[1] == 'push') then
  if not arg[2] then
    print('push requires uuid argument')
    exit(1)
  end

  local stream = StreamModel:find({uuid = arg[2]})
  local sas = stream:get_streams_accounts()

  local ffmpeg_args = {
    '-re',
    '-v',
    'error',
    '-i',
    config.private_rtmp_url ..'/'.. config.rtmp_prefix ..'/'..arg[2],
  }
  for _,sa in pairs(sas) do
    insert(ffmpeg_args,'-codec:v')
    insert(ffmpeg_args,'copy')
    insert(ffmpeg_args,'-codec:a')
    insert(ffmpeg_args,'copy')
    insert(ffmpeg_args,'-map_metadata')
    insert(ffmpeg_args,'0')
    insert(ffmpeg_args,'-f')
    insert(ffmpeg_args,'flv')
    insert(ffmpeg_args,sa.rtmp_url)
  end

  posix.exec(config.ffmpeg,ffmpeg_args)

end


