local len = string.len
local insert = table.insert
local byte = string.byte
local char = string.char

local M = {}
M.__index = M

function M.parse(line)
  local i = 1
  local max = len(line)
  local args = {}
  local arg = ""
  local in_quote = false

  repeat
    local b = byte(line,i)
    if in_quote == true then
      if b == 34 then -- end quote
        in_quote = false
      else
        arg = arg .. char(b)
      end
    else
      if b == 32 then -- space
        if len(arg) > 0 then
          insert(args,arg)
        end
        arg = ""
      elseif b == 34 then -- being quote
        in_quote = true
      else
        arg = arg .. char(b)
      end
    end
    i = i + 1
  until i > max
  if len(arg) > 0 then
    insert(args,arg)
  end

  return args
end

return M
