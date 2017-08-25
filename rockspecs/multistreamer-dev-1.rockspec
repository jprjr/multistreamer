package = "multistreamer"
version = "dev-1"

source = {
  url = "..."
}

dependencies = {
  "lua >= 5.1",
  "lua-resty-exec",
  "lua-resty-jit-uuid",
  "lua-resty-http",
  "lapis",
  "etlua",
  "luacrypto",
  "luaposix",
  "luafilesystem",
  "whereami",
}

build = {
  type = "none",
}


