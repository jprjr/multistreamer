local config = require('lapis.config').get()
local gsub = string.gsub

config.VERSION = '10.2.0'

if not config.log_level or config.log_level:len() == 0 then
  config.log_level = 'debug'
end

if not config.redis_prefix or config.redis_prefix:len() == 0 then
  config.redis_prefix = 'multistreamer/'
end

if not config.redis_host or config.redis_host:len() == 0 then
  config.redis_host = '127.0.0.1:6379'
end

if not config.rtmp_prefix or config.rtmp_prefix:len() == 0 then
  config.rtmp_prefix = 'multistreamer'
end

if not config.http_prefix then
  config.http_prefix = ''
end

if not config.http_listen then
  config.http_listen = '127.0.0.1:8081'
end

if not config.rtmp_listen then
  config.rtmp_listen = '127.0.0.1:1935'
end

if not config.irc_listen then
  config.irc_listen = '127.0.0.1:6667'
end

if not config.irc_hostname then
  config.irc_hostname = 'localhost'
end

if not config.public_http_url then
  config.public_http_url = 'http://127.0.0.1:8081'
end
if not config.public_rtmp_url then
  config.public_rtmp_url = 'rtmp://127.0.0.1:1935'
end
if not config.private_http_url then
  config.private_http_url = 'http://127.0.0.1:8081'
end
if not config.private_rtmp_url then
  config.private_rtmp_url = 'rtmp://127.0.0.1:1935'
end
if not config.public_irc_hostname then
  config.public_irc_hostname = 'localhost'
end
if not config.public_irc_hostname then
  config.public_irc_port = '6667'
end
if not config.public_irc_ssl then
  config.public_irc_ssl = false
end
if not config.irc_motd then
  config.irc_motd = [[Welcome to Multistreamer!]]
end

if not config.lua_shared_dict_streams_size then
  config.lua_shared_dict_streams_size = '1m'
end

if not config.lua_shared_dict_writers_size then
  config.lua_shared_dict_writers_size = '1m'
end

if config.allow_transcoding == nil then
  config.allow_transcoding = true
end

if config.allow_custom_puller == nil then
  config.allow_custom_puller = true
end

config.http_prefix      = gsub(config.http_prefix,'/+$','')
config.public_http_url  = gsub(config.public_http_url,'/+$','')
config.public_rtmp_url  = gsub(config.public_rtmp_url,'/+$','')
config.private_http_url = gsub(config.private_http_url,'/+$','')
config.private_rtmp_url = gsub(config.private_rtmp_url,'/+$','')

if type(config.networks.beam) == 'table' and not config.networks.mixer then
  config.networks.mixer = {
    client_secret = config.networks.beam.client_secret,
    client_id     = config.networks.beam.client_id,
    ingest_server = gsub(config.networks.beam.ingest_server,'beam.pro','mixer.com'),
  }
  config.networks.beam = nil
end

return config
