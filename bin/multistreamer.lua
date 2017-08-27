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
local bash_path   = streamer_dir ..'/bin/multistreamer'
posix.chdir(streamer_dir)

local commands = {
  ['run'] = 1,
  ['initdb'] = 1,
  ['psql'] = 1,
  ['dump_yaml'] = 1,
  ['push'] = 1, -- internal command
  ['pull'] = 1, -- internal command
}

local sql_files = {
  [1]  = streamer_dir .. '/sql/1477785578.sql',
  [2]  = streamer_dir .. '/sql/1481421931.sql',
  [3]  = streamer_dir .. '/sql/1485029477.sql',
  [4]  = streamer_dir .. '/sql/1485036089.sql',
  [5]  = streamer_dir .. '/sql/1485788609.sql',
  [6]  = streamer_dir .. '/sql/1489949143.sql',
  [7]  = streamer_dir .. '/sql/1492032677.sql',
  [8]  = streamer_dir .. '/sql/1497734864.sql',
  [9]  = streamer_dir .. '/sql/1500610370.sql',
  [10] = streamer_dir .. '/sql/1503806092.sql',
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
  if not lfs.attributes(config.ffmpeg) then
    print('Error: ffmpeg binary does not exist')
    exit(1)
  end
  if not config.sockexec_path then
    print('Error: path to sockexec socket not set')
    exit(1)
  end

  config.lua_bin = lua_bin
  config.script_path = script_path;
  config.bash_path   = bash_path;

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
  for _,f in ipairs(sql_files) do
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
  if not arg[2] or not arg[3] then
    print('push requires stream id, account id arguments')
    exit(1)
  end

  local shell = require'multistreamer.shell'
  local Stream = require'models.stream'
  local StreamAccount = require'models.stream_account'
  local stream = Stream:find({ id = arg[2] })
  local sa = StreamAccount:find({stream_id = arg[2], account_id = arg[3]})
  local account = sa:get_account()

  local ffmpeg_args = {
    '-v',
    'error',
    '-copyts',
    '-vsync',
    '0',
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

  local _, err = posix.exec(config.ffmpeg,ffmpeg_args)
  print(err)
  exit(1)

elseif(arg[1] == 'pull') then
  if not arg[2] then
    print('pull requires id argument')
    exit(1)
  end

  local shell = require'multistreamer.shell'
  local StreamModel = require'models.stream'
  local stream = StreamModel:find({id = arg[2]})

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
  local _, err = posix.exec(config.ffmpeg,ffmpeg_args)
  print(err)
  exit(1)

elseif(arg[1] == 'dump_yaml') then

  if config.logging.queries then
    config.logging.queries = 'true'
  else
    config.logging.queries = 'false'
  end
  if config.logging.requests then
    config.logging.requests = 'true'
  else
    config.logging.requests = 'false'
  end

  if config.public_irc_ssl then
    config.public_irc_ssl = 'true'
  else
    config.public_irc_ssl = 'false'
  end

  if config.networks.rtmp then
    config.networks.rtmp = 'true'
  else
    config.networks.rtmp = 'false'
  end
  if config.irc_force_join then
    config.irc_force_join = 'true'
  else
    config.irc_force_join = 'false'
  end

  if config.allow_transcoding then
    config.allow_transcoding = 'true'
  else
    config.allow_transcoding = 'false'
  end
  if config.allow_custom_puller then
    config.allow_custom_puller = 'true'
  else
    config.allow_custom_puller = 'false'
  end

  local yaml_template = [[
### name of the cookie used to store session data
session_name: '<%= session_name %>'

### key for encrypting session data
secret: '<%= secret %>'

### whether to log queries and requests
logging:
  queries: <%= logging.queries %>
  requests: <%= logging.requests %>

### if deploying somewhere other than the root of a domain
### set this to your prefix (ie, '/multistreamer')
http_prefix: '<%= http_prefix %>'

### set an rtmp prefix
### note: this can only be a single string
### no slashes etc
### defaults to 'multistreamer' if unset
rtmp_prefix: '<%= rtmp_prefix %>'

### path to your nginx+lua+rtmp binary
nginx: '<%= nginx %>'

### path to psql
psql: '<%= psql %>'

### path to ffmpeg
ffmpeg: '<%= ffmpeg %>'

### set your logging level
log_level: '<%= log_level %>'

### setup your external urls (without prefixes)
public_http_url: '<%= public_http_url %>'
public_rtmp_url: '<%= public_rtmp_url %>'

### setup your private (loopback) urls (without prefixes)
private_http_url: '<%= private_http_url %>'
private_rtmp_url: '<%= private_rtmp_url %>'

### setup your public IRC hostname, for the web
### interface
public_irc_hostname: '<%= public_irc_hostname %>'

### setup your public IRC port, to report in the
### web interface
public_irc_port: '<%= public_irc_port %>'

### set to true if you've setup an SSL terminator in front
### of multistreamer
public_irc_ssl: <%= public_irc_ssl %>


### configure streaming networks/services
### you'll need to register a new app with each
### service and insert keys/ids in here

### 'rtmp' just stores RTMP urls and has no config
networks:
  <% if networks.mixer then %>
  mixer:
    client_id: '<%= networks.mixer.client_id %>'
    client_secret: '<%= networks.mixer.client_secret %>'
    ingest_server: '<%= networks.mixer.ingest_server %>'
  <% else %>
  #mixer:
  #  client_id: 'client_id'
  #  client_secret: 'client_secret'
  #  ingest_server: 'rtmp://somewhere'
  <% end %>

  <% if networks.twitch then %>
  twitch:
    client_id: '<%= networks.twitch.client_id %>'
    client_secret: '<%= networks.twitch.client_secret %>'
    ingest_server: '<%= networks.twitch.ingest_server %>'
    # see https://bashtech.net/twitch/ingest.php
    # for a list of endpoints
  <% else %>
  #twitch:
  #  client_id: 'client_id'
  #  client_secret: 'client_secret'
  #  ingest_server: 'rtmp://somewhere'
    # see https://bashtech.net/twitch/ingest.php
    # for a list of endpoints
  <% end %>

  <% if networks.facebook then %>
  facebook:
    app_id: '<%= networks.facebook.app_id %>'
    app_secret: '<%= networks.facebook.app_secret %>'
  <% else %>
  #facebook:
  #  app_id: 'app_id'
  #  app_secret: 'app_secret'
  <% end %>

  <% if networks.youtube then %>
  youtube:
    client_id: '<%= networks.youtube.client_id %>'
    client_secret: '<%= networks.youtube.client_secret %>'
    country: '<%= networks.youtube.country %>'
    # 2-character country code, used for listing available categories
  <% else %>
  #youtube:
  #  client_id: 'client_id'
  #  client_secret: 'client_secret'
  #  country: 'us'
    # 2-character country code, used for listing available categories
  <% end %>

  rtmp: <%= networks.rtmp %>

### postgres connection settings
postgres:
  host: '<%= postgres.host %>'
  user: '<%= postgres.user %>'
  password: '<%= postgres.password %>'
  database: '<%= postgres.database %>'
  <% if postgres.port then %>port: '<%= postgres.port %>'<% else %>port: 5432<% end %>

### nginx http "listen" directive, see
### http://nginx.org/en/docs/http/ngx_http_core_module.html#listen
http_listen: '<%= http_listen %>'

### nginx rtmp "listen" directive, see
### https://github.com/arut/nginx-rtmp-module/wiki/Directives#listen
### default: listen on all ipv6+ipv4 addresses
rtmp_listen: '<%= rtmp_listen %>'

### nginx irc "listen" directive, see
### https://nginx.org/en/docs/stream/ngx_stream_core_module.html#listen
### default: listen on all ipv6+ipv4 addresses
irc_listen: '<%= irc_listen %>'

### set the IRC hostname reported by the server
irc_hostname: '<%= irc_hostname %>'

### should users be automatically brought into chat rooms when
### their streams go live? (default false)
### this is handy for clients like Adium, Pidgin, etc that don't
### have a great IRC interface
irc_force_join: <%= irc_force_join %>

### number of worker processes
worker_processes: <%= worker_processes %>

### http auth endpoint
### multistreamer will make an HTTP request with the 'Authorization'
### header to this URL when a user logs in
### see http://nginx.org/en/docs/http/ngx_http_auth_request_module.html
### see https://github.com/jprjr/ldap-auth-server for an LDAP implementation
auth_endpoint: '<%= auth_endpoint %>'

### redis host
redis_host: '<%= redis_host %>'

### prefix for redis keys
redis_prefix: '<%= redis_prefix %>'

### path to trusted ssl certificate store
ssl_trusted_certificate: '<%= ssl_trusted_certificate %>'

### dns resolver
dns_resolver: '<%= dns_resolver %>'

### maximum ssl verify depth
ssl_verify_depth: <%= ssl_verify_depth %>

### sizes for shared dictionaries (see https://github.com/openresty/lua-nginx-module#lua_shared_dict)
lua_shared_dict_streams_size: '<%= lua_shared_dict_streams_size %>'
lua_shared_dict_writers_size: '<%= lua_shared_dict_writers_size %>'

### specify the run directory to hold temp files etc
### defaults to $HOME/.multistreamer if not set
<% if work_dir then -%>
work_dir: '<%= work_dir %>'
<% else -%>
#work_dir: ''
<% end %>

### set the path to sockexec's socket
### see https://github.com/jprjr/sockexec for installation details
sockexec_path: '<%= sockexec_path %>'

### allow/disallow transcoding (default: true)
allow_transcoding: <%= allow_transcoding %>

### allow/disallow creating pullers (default: true)
allow_custom_puller: <%= allow_custom_puller %>
]]

  local template = etlua.compile(yaml_template)
  print(template(config))


end


