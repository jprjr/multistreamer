-- luacheck: globals ngx
local ngx = ngx
local config = require'multistreamer.config'
local table_insert = table.insert
local table_sort = table.sort
local pairs = pairs
local pcall = pcall

local ngx_log = ngx.log
local ngx_err = ngx.ERR

local M = {}
local _networks = {}

if not config.networks then config.networks = {} end

local function load_network(k)
  local ok, helper = pcall(require,'multistreamer.networks.'..k)
  if ok then
    _networks[k] = helper
  else
    ngx_log(ngx_err,helper)
  end
end

for k,_ in pairs(config.networks) do
  load_network(k)
end

setmetatable(M, {
  __index = function(_,k)
    if k == 'beam' then
      k = 'mixer'
    end
    return _networks[k]
  end,
  __call = function()

    local i = 0
    local t = {}
    for k in pairs(_networks) do table_insert(t,{ name = k, displayname = _networks[k].displayname} ) end
    table_sort(t, function (a,b)
      return a.displayname < b.displayname
    end)

    local _iter = function()
      i = i + 1
      if not t[i] then return nil end
      return t[i].name, _networks[t[i].name]
    end

    return _iter

  end,
})

return M
