local string = string
local find = string.find
local sub  = string.sub
local len  = string.len
local insert = table.insert
local concat = table.concat
local format = string.format

local s = {}

local function split(self,inSplitPattern)
  local res = {}
  local start = 1
  local splitStart, splitEnd = find(self,inSplitPattern,start)
  while splitStart do
    insert(res, sub(self,start,splitStart-1))
    start = splitEnd + 1
    splitStart, splitEnd = find(self,inSplitPattern, start)
  end
  insert(res, sub(self,start) )
  return res
end

local function to_table(self)
  local res = {}
  local max = len(self)
  for i=1,max,1 do
    res[i] = sub(self,i,i)
  end
  return res
end

local markdown_table = {
    ['>'] = '&gt;',
    ['<'] = '&lt;',
    ['!'] = '\\!',
    ['`'] = '\\`',
    ['*'] = '\\*',
    ['_'] = '\\_',
    ['{'] = '\\{',
    ['}'] = '\\}',
    ['['] = '\\[',
    [']'] = '\\]',
    ['('] = '\\(',
    [')'] = '\\)',
    ['#'] = '\\#',
    ['+'] = '\\+',
    ['-'] = '\\-',
    ['.']  = '\\.',
    ['\\'] = '\\\\',
}

local function escape_markdown(self)
  if(len(self) == 1) then
    return markdown_table[self] or self
  end

  local tokens = split(self,' ')
  for i=1,#tokens,1 do
    if find(tokens[i],"^https?://") then
      tokens[i] = format('[%s](%s)',tokens[i],tokens[i])
    else
      local chars = to_table(tokens[i])
      for j=1,#chars,1 do
        if markdown_table[chars[j]] then
          chars[j] = markdown_table[chars[j]]
        end
      end
      tokens[i] = concat(chars,'')
    end
  end

  return concat(tokens,' ')
end

for k,_ in pairs(string) do
  s[k] = string[k]
end

s.escape_markdown = escape_markdown
s.to_table = to_table
s.split = split

return s
