local posix  = require'posix'
local etlua  = require'etlua'
local getopt = require'multistreamer.getopt'
local config = require'multistreamer.config'
local version = require'multistreamer.version'
local pgmoon = require'pgmoon'
local lfs = require'lfs'
local redis = require'redis'

local getenv = os.getenv
local exit   = os.exit
local len    = string.len
local insert = table.insert
local sub = string.sub
local find = string.find

local optarg, optind

local function help(code)
  io.stderr:write('Usage: multistreamer [-c /path/to/config.yaml] <action>\n')
  io.stderr:write('Available actions:\n')
  io.stderr:write('  run           -- run server\n')
  io.stderr:write('  check         -- check config file\n')
  io.stderr:write('  listusers     -- list current users\n')
  io.stderr:write('  deluser [id]  -- delete user\n')
  io.stderr:write('  initdb        -- setup database manually\n')
  return code
end

local function try_load_config(check)
  check = check or false
  local filename,filename_list,err,_
  filename, filename_list = config.find_conf_file(optarg['c'])
  if not filename then
    io.stderr:write('Unable to find config file. Searched paths:\n')
    for _,v in pairs(filename_list) do
      io.stderr:write('  ' .. v .. '\n')
    end
    return 1
  end

  if check then
    io.stderr:write('Testing config file ' .. filename .. '\n')
  end
  _,err = config.loadconfig(filename)
  if err then
    io.stderr:write('Error loading config: ' .. err .. '\n')
    return 1
  end

  local c = config.get()

  if not c['nginx'] then
    io.stderr:write('nginx not specified\n')
    return 1
  end

  if not posix.stdlib.realpath(c['nginx']) then
    io.stderr:write('path to nginx does not exist\n')
    return 1
  end

  local nginx_handle = io.popen(c['nginx'] .. ' -V 2>&1 | grep lua')
  local res = nginx_handle:read('*all')
  nginx_handle:close()

  if len(res) == 0 then
    io.stderr:write("nginx doesn't support lua\n")
    return 1
  end

  if not c['postgres'] or type(c['postgres']) ~= 'table' then
    io.stderr:write('config missing postgres section\n')
    return 1
  end

  local pg = pgmoon.new(c['postgres'])
  _, err = pg:connect()
  if err then
    io.stderr:write('Unable to connect to postgres: ' .. err .. '\n')
    return 1
  end

  local _, err = pcall(function()
    redis.connect(c.redis_host,c.redis_port)
  end)
  if err then
    io.stderr:write('Unable to connect to redis: ' .. err .. '\n')
    return 1
  end

  if optarg['V'] then
    io.stderr:write(c['_raw'] .. '\n')
  end

  if check then
    io.stderr:write('OK\n')
  end

  return 0
end

local functions = {
  ['run'] = function()
    local res = try_load_config()
    if res ~= 0 then
      return res
    end
    local c = config.get()

    if not posix.stdlib.realpath(c['work_dir']) then
      posix.mkdir(c['work_dir'])
    end
    if not posix.stdlib.realpath(c['work_dir'] .. '/logs') then
      posix.mkdir(c['work_dir'] .. '/logs')
    end

    posix.setenv('CONFIG_FILE',c._filename)
    posix.setenv('LUA_PATH',package.path)
    posix.setenv('LUA_CPATH',package.cpath)

    local nginx_conf = etlua.compile(require'multistreamer.nginx-conf')
    local nof = io.open(c['work_dir'] .. '/nginx.conf', 'wb')
    nof:write(nginx_conf(c))
    nof:close()

    require'multistreamer.migrations'
    posix.exec(c['nginx'], { '-p', c['work_dir'], '-c', c['work_dir'] .. '/nginx.conf' } )
    return 0
  end,

  ['check'] = function()
    local res = try_load_config(true)
    if res ~= 0 then
      return res
    end
    return 0
  end,

  ['listusers'] = function()
    local res = try_load_config(false)
    if res ~= 0 then return 1 end
    local User = require'multistreamer.models.user'
    for _,v in ipairs(User:select("order by id")) do
      print(v.id,v.username)
    end
    return 0
  end,

  ['deluser'] = function(userid)
    if not userid then return help(1) end
    local res = try_load_config(false)
    if res ~= 0 then return 1 end
    local User = require'multistreamer.models.user'
    local Account = require'multistreamer.models.account'
    local Keystore = require'multistreamer.models.keystore'
    local SharedAccount = require'multistreamer.models.shared_account'
    local SharedStream = require'multistreamer.models.shared_stream'
    local StreamAccount = require'multistreamer.models.stream_account'
    local Stream = require'multistreamer.models.stream'
    local Webhook = require'multistreamer.models.webhook'
    local u = User:find({id = userid})
    if not u then
      print('User not found')
    else
      print('Deleting user ' .. u.username)
      for _,s in ipairs(Stream:select({user_id = u.id})) do
        for _,sa in ipairs(StreamAccount:select({stream_id = s.id})) do
          local ks = Keystore(sa.id,s.id)
          ks:unset_all()
          sa:delete()
        end
        for _,ss in ipairs(SharedStream:select({ stream_id = s.id})) do
          ss:delete()
        end
        for _,wh in ipairs(Webhook:select({ stream_id = s.id })) do
          wh:delete()
        end
        local ks = Keystore(nil,s.id)
        ks:unset_all()
        s:delete()
      end
      for _,a in ipairs(Account:select({user_id = u.id})) do
        for _,sa in ipairs(SharedAccount:select({ account_id = a.id})) do
          sa:delete()
        end
        local ks = Keystore(a.id,nil)
        ks:unset_all()
        a:delete()
      end

      u:delete()
    end
    return 0
  end,

  ['initdb'] = function()
    local res = try_load_config()
    if res ~= 0 then
      return res
    end
    return require'multistreamer.migrations'
  end,
}

local function main(args)
  local _, err
  _, err = pcall(function()
    optarg,optind = getopt.get_opts(args,'l:hVvc:',{})
  end)

  if err then
    io.stderr:write('Error parsing argments: ' .. err .. '\n')
    return help(1)
  end

  if optarg['v'] then
    io.stderr:write('multistreamer version ' .. version.STRING .. '\n')
    return 0
  end

  if optarg['h'] then
    return help(0)
  end

  if not args[optind] or not functions[args[optind]] then
    return help(1)
  end

  local func_args = {}
  for k=optind+1,#args,1 do
    insert(func_args,args[k])
  end

  return functions[args[optind]](unpack(func_args))
end

return main
