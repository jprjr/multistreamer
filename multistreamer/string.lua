local string = string
local find = string.find
local sub  = string.sub
local len  = string.len
local char = string.char
local insert = table.insert
local concat = table.concat

function string:split(inSplitPattern)
  local res = {}
  local start = 1
  local splitStart, splitEnd = self:find(inSplitPattern,start)
  while splitStart do
    insert(res, sub(self,start,splitStart-1))
    start = splitEnd + 1
    splitStart, splitEnd = self:find(inSplitPattern, start)
  end
  insert(res, self:sub(start) )
  return res
end

function string:to_table()
  local res = {}
  local max = self:len()
  for i=1,max,1 do
    res[i] = self:sub(i,i)
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

function string:escape_markdown()
  local tokens = self:to_table()
  local i = 1
  for i=1,#tokens,1 do
    if markdown_table[tokens[i]] then
      tokens[i] = markdown_table[tokens[i]]
    end
  end

  return concat(tokens,'')
end

return string
