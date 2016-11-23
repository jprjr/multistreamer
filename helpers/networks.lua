local config = require('lapis.config').get()
local table_insert = table.insert
local table_sort = table.sort
local pairs = pairs
local pcall = pcall

local M = {}
local networks = {}

if not config.networks then config.networks = {} end
for k,v in pairs(config.networks) do
  local ok, helper = pcall(require,'networks.'..k)
  if ok then
    networks[k] = helper
    networks[k].name = k
    if networks[k].get_oauth_url then
      networks[k].redirect_uri = config.public_http_url .. config.http_prefix .. '/auth/' .. k
    end
  end
end

setmetatable(M, {
  __index = function(t,k)
    return networks[k]
  end,
  __call = function(t,k)

    local i = 0
    local t = {}
    for k in pairs(networks) do table_insert(t,{ name = k, displayname = networks[k].displayname} ) end
    table_sort(t, function (a,b)
      return a.displayname < b.displayname
    end)

    local _iter = function()
      i = i + 1
      if not t[i] then return nil end
      return t[i].name, networks[t[i].name]
    end

    return _iter

  end,
})

return M
