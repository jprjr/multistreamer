local http = require'resty.http'
local encode_query_string = require('lapis.util').encode_query_string
local string = require'multistreamer.string'
local find = string.find

local M = {}
M.__index = M

local function default_error_handler(res)
  return res
end

function M.new(error_handler)
  local t = {}
  t.httpc = http.new()
  t.error_handler = error_handler or default_error_handler

  setmetatable(t,M)
  return t
end

function M.request(self,method,url,params,headers,body)
  if params then
    url = url .. '?' .. encode_query_string(params)
  end

  local res, err = self.httpc:request_uri(url, {
    method = method,
    headers = headers,
    body = body,
  })

  if res and type(res.status) ~= 'number' then
    res.status = tonumber(find(res.status,'^%d+'))
  end

  if err or res.status >= 400 then
    return false, err or self.error_handler(res)
  end

  return res, nil
end

function M.get(self,url,params,headers,body)
  return M.request(self,'GET',url,params,headers,body)
end

function M.post(self,url,params,headers,body)
  return M.request(self,'POST',url,params,headers,body)
end

function M.patch(self,url,params,headers,body)
  return M.request(self,'PATCH',url,params,headers,body)
end

function M.put(self,url,params,headers,body)
  return M.request(self,'PUT',url,params,headers,body)
end

function M.delete(self,url,params,headers,body)
  return M.request(self,'DELETE',url,params,headers,body)
end

return M
