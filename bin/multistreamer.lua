#!/usr/bin/env lua

local getenv = os.getenv
local exit = os.exit

local multistreamer_env = getenv('LAPIS_ENVIRONMENT')
if not multistreamer_env then
  print('LAPIS_ENVIRONMENT not set')
  exit(1)
end

local posix = require'posix'
local len = string.len
local etlua = require'etlua'
local insert = table.insert

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
  [2] = streamer_dir .. '/sql/1481421931.sql',
  [3] = streamer_dir .. '/sql/1485029477.sql',
  [4] = streamer_dir .. '/sql/1485036089.sql',
  [5] = streamer_dir .. '/sql/1485788609.sql',
}

if(not arg[1] or not commands[arg[1]]) then
  print('syntax: ' ..  script_path .. ' <action>')
  print('Available actions')
  print('  run    -- run nginx')
  print('  initdb -- initialize the database')
  print('  psql <file>   -- launch psql, runs sql if provided')
  exit(1)
end


local config = require'multistreamer.config'

if not config.auth_endpoint then
  print('Error: auth_endpoint not set in config')
  exit(1)
end

if not config.secret or config.secret == 'CHANGEME' then
  print('Error: secret not set or still at default')
  exit(1)
end

config.multistreamer_env = multistreamer_env

if(arg[1] == 'run') then
  local whereami = require'whereami'
  local lua_bin = whereami()
  local lfs = require'lfs'

  if not config.nginx then
    print('Error: path to nginx not set')
    exit(1)
  end
  if not config.ffmpeg then
    print('Error: path to ffmpeg not set')
    exit(1)
  end

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

  local _, err = posix.exec(config.nginx, { '-p', config.work_dir, '-c', 'nginx.'..multistreamer_env..'.conf' })
  -- if we get here it's an error
  print(err)
  exit(1)

elseif(arg[1] == 'psql') then
  posix.setenv('PGPASSWORD',config.postgres.password)
  local args = { '-U', config.postgres.user, '-h' , config.postgres.host }
  if arg[2] then
    table.insert(args,'-f')
    table.insert(args,arg[2])
  end
  local _, err = posix.exec(config.psql, args)
  print(err)
  exit(1)

elseif(arg[1] == 'initdb') then
  posix.setenv('PGPASSWORD',config.postgres.password)
  for i,f in ipairs(sql_files) do
    local pid, errmsg = posix.fork()
    if pid == nil then
      print(errmsg)
      exit(1)
    elseif pid == 0 then
      local _, err = posix.exec(config.psql, { '-U', config.postgres.user, '-h' , config.postgres.host, '-f', f })
      print(err)
      exit(1)
    else
      posix.wait(pid)
    end
  end

elseif(arg[1] == 'push') then
  if not arg[2] then
    print('push requires uuid argument')
    exit(1)
  end

  local shell = require'multistreamer.shell'
  local StreamModel = require'models.stream'
  local stream = StreamModel:find({uuid = arg[2]})
  local sas = stream:get_streams_accounts()

  local ffmpeg_args = {
    '-v',
    'error',
    '-i',
    config.private_rtmp_url ..'/'.. config.rtmp_prefix ..'/'..arg[2],
  }
  for _,sa in pairs(sas) do
    local account = sa:get_account()
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

    for i,v in pairs(args) do
      insert(ffmpeg_args,v)
    end

    insert(ffmpeg_args,'-f')
    insert(ffmpeg_args,'flv')
    insert(ffmpeg_args,sa.rtmp_url)
  end

  local _, err = posix.exec(config.ffmpeg,ffmpeg_args)
  print(err)
  exit(1)

end


