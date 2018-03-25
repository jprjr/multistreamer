local posix  = require'posix'
local sys_stat = require'posix.sys.stat'
local dir_sep, path_sep, sub_char
local gmatch = string.gmatch
local match = string.match
local gsub = string.gsub
local open = io.open
local close = io.close
local sort = table.sort

for m in gmatch(package.config, '[^\n]+') do
  local m = gsub(m,'([^%w])','%%%1')
  if not dir_sep then dir_sep = m
    elseif not path_sep then path_sep = m
    elseif not sub_char then sub_char = m end
end

local function find_lib(name)
  for m in gmatch(package.path, '[^' .. path_sep ..';]+') do
    local mod_path, r = gsub(m,sub_char,gsub(name,'%.',dir_sep))
    if(r > 0) then
      if sys_stat.stat(mod_path) then return mod_path end
    end
  end
end

local function copy_table(a,b) -- a = dest, b = src
  for k,v in pairs(b) do
    local t = type(v)
    if t ~= 'table' then
      if a[k] == nil then
        a[k] = b[k]
      end
    else
      if a[k] == nil then
        a[k] = {}
      end
      copy_table(a[k],v)
    end
  end
end

local function load_langs(langs)
  local lib_dir = gsub(find_lib('multistreamer.lang'),'%.lua$','')
  for f in posix.dirent.files(lib_dir) do
    if match(f,'%.lua$') then
      local l_name = gsub(f,'%.lua$','')
      if l_name ~= 'en_us' then
        local f_name = 'multistreamer.lang.' .. l_name
        langs[l_name] = require(f_name)
        copy_table(langs[l_name],langs['en_us'])
      end
    end
  end
end

local langs = {}
langs['en_us'] = require'multistreamer.lang.en_us'
load_langs(langs)

return langs


