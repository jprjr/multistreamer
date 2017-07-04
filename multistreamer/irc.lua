local char = string.char
local byte = string.byte
local sub  = string.sub
local find = string.find
local len  = string.len
local insert = table.insert
local ipairs = ipairs
local type = type

local IRC = {}
IRC.__index = IRC

function IRC.parse_line(data)
    local i = 1;
    local max = len(data)

    local msg = {
        tags = {},
        prefix = nil,
        command = nil,
        args = {},
        raw = data
    }

    if(byte(data,i) == 64) then
        i = i + 1
        if(i > max) then return end
        local cur_tag = nil
        local cur_val = nil
        repeat
            local t = byte(data,i)
            if(t == 32) then
                if cur_tag then
                    msg.tags[cur_tag] = cur_val
                end
            elseif(t == 59) then
                msg.tags[cur_tag] = cur_val
                cur_tag = nil
                cur_val = nil
            elseif(t == 61) then
                cur_val = ""
            else
                if(not cur_tag) then
                    cur_tag = char(t)
                else
                    if(not cur_val) then
                        cur_tag = cur_tag .. char(t)
                    else
                        cur_val = cur_val .. char(t)
                    end
                end
            end
            i = i + 1
        until (t == 32 or i > max)
    end

    if(byte(data,i) == 58) then
        msg.prefix = ""
        i = i + 1
        if(i > max) then return end
        repeat
            local t = byte(data,i)
            if(t ~= 32) then
                msg.prefix = msg.prefix .. char(t)
            end
            i = i + 1
        until (t == 32 or i > max)
    end

    repeat
        local t = byte(data,i)
        if t and t ~= 32 then
          if(not msg.command) then
              msg.command = char(t)
          else
              msg.command = msg.command .. char(t)
          end
        end
        i = i + 1
    until(t == nil or t == 32 or i > max)

    local cur_arg = nil
    repeat
        local t = byte(data,i)
        if t then
          if(t == 58 and not cur_arg) then
              cur_arg = sub(data,i+1,max)
              i = max
          elseif(t == 32) then
              if(cur_arg) then
                  insert(msg.args,cur_arg)
                  cur_arg = nil
              else
                  cur_arg = char(t)
              end
          elseif(t) then
              if(cur_arg) then
                  cur_arg = cur_arg .. char(t)
              else
                  cur_arg = char(t)
              end
          end
        end
        i = i + 1
    until(t == nil or i > max)
    insert(msg.args,cur_arg)

    if(msg.prefix) then
        i = 1
        local f = 0 -- 0: unknown
                    -- 1: server
                    -- 2: nick
                    -- 3: user
                    -- 4: host
        local server = nil
        local nick   = nil
        local user   = nil
        local host   = nil
        local cur    = ''
        repeat
            local t = byte(msg.prefix,i)
            if t then
              if(t == 46 and f == 0) then -- '.' and still unknown means this is a server
                  f = 1
                  cur = cur .. char(t)
              elseif(t == 33 and f == 0) then -- '!' and still unknown, just saw nickname, now working on user
                  f = 3
                  nick = cur
                  cur = ''
              elseif(t == 64) then -- '@' means we're now working on a host
                                   -- maybe saw a user, maybe saw a nick
                  if(f == 0) then
                      nick = cur
                  elseif(f == 3) then
                      user = cur
                  end
                  cur = ''
                  f = 4
              else
                  cur = cur .. char(t)
              end
            end
            i = i + 1
        until(t == nil)

        if(f == 0) then
            nick = cur
        elseif(f == 1) then
            server = cur
        elseif(f==3) then
            user = cur
        elseif(f==4) then
            host = cur
        end
        msg.from = {
            server = server,
            nick = nick,
            user = user,
            host = host
        }
    end
    return msg
end

function IRC.format_line(...)
  local msg = ''

  for i,v in ipairs({...}) do
    if i == #{...} and (type(v) == 'string' and find(v,' ')) then
      v = ':' .. v
    end
    if i > 1 then
      v = ' ' .. v
    end
    if v ~= nil then
      msg = msg .. v
    end
  end
  return msg
end

-- a variant of format_line that always places
-- a colon on the last argument
function IRC.format_line_col(...)
  local msg = ''
  for i,v in ipairs({...}) do
    if i == #{...} and (type(v) == 'string') then
      v = ':' .. v
    end
    if i > 1 then
      v = ' ' .. v
    end
    if v ~= nil then
      msg = msg .. v
    end
  end
  return msg
end

return IRC

