# multistreamer

Like this? I do this for fun in my spare time, but I'll never say
no to being bought a beer!

[![Donate](https://img.shields.io/badge/Donate-PayPal-green.svg)](https://www.paypal.com/cgi-bin/webscr?cmd=_s-xclick&hosted_button_id=NNKN85X52NEP6)
[![Flattr this git repo](http://api.flattr.com/button/flattr-badge-large.png)](https://flattr.com/submit/auto?user_id=jprjr&url=https://github.com/jprjr/multistreamer&title=multistreamer&language=en_GB&tags=github&category=software)

If you want to get this up and running quickly, check out my Docker
image - https://github.com/jprjr/docker-multistreamer and its corresponding
video - https://youtu.be/HdDDtBOLme4

This is a tool for simulcasting RTMP streams to multiple services:

* [Mixer](https://github.com/jprjr/multistreamer/wiki/Mixer)
* [Facebook](https://github.com/jprjr/multistreamer/wiki/Facebook)
* [Twitch](https://github.com/jprjr/multistreamer/wiki/Twitch)
* [YouTube](https://github.com/jprjr/multistreamer/wiki/YouTube)

It allows users to add accounts for their favorite streaming services,
and gives an endpoint for them to push video to. Their video stream will
be relayed to multiple accounts.

It also allows for updating their stream's metadata (stream title,
description, etc) from a single page, instead of logging into multiple
services.

It supports integration with Discord via webhooks - it can push your
stream's incoming comments/chat messages to a Discord channel, as well
as updates when you've started/stopped streaming. There's also a "raw"
webhook, if you want to develop your own application that responds
to events. See [the wiki](https://github.com/jprjr/multistreamer/wiki/Webhook)
for details.

Additionally, it provides an IRC interface, where users can read/write
comments and messages in a single location. There's also a web interface
for viewing and replying to comments, and a chat widget you can embed
into OBS (or anything else supporting web-based sources).

Not all services support writing comments/messages from the web or IRC
interfaces - please see the [wiki](https://github.com/jprjr/multistreamer/wiki) for
details on which services support which features.

Fun, unintentional side effect: you can use this to push video to your
personal Facebook profile, instead of using the phone app. This isn't
available via the regular Facebook web interface, as far as I know. :)

Please note: you're responsible for ensuring you're not violating each
service's Terms of Service via simulcasting.

Here's some guides on installing/using:

* [My User Guide](https://github.com/jprjr/multistreamer/wiki/User-Guide)
* [A short intro video](https://youtu.be/NBNLqaUn9mA)
* [A in-depth tutorial for users](https://youtu.be/Uz2vXppsMIw)
* [Installing multistreamer with Docker](https://youtu.be/HdDDtBOLme4)
* [Installing multistreamer without Docker](https://youtu.be/Wr4CD6RU_CU)

## Table of Contents

* [Requirements](#requirements)
* [Installation](#installation)
  + [Install with Docker](#install-with-docker)
  + [Install OpenResty with `setup-openresty`](#install-openresty-with-setup-openresty)
  + [Alternative: Install OpenResty with RTMP Manually](#alternative-install-openresty-with-rtmp-manually)
  + [Setup database and user in Postgres](#setup-database-and-user-in-postgres)
  + [Setup Redis](#setup-redis)
  + [Setup Sockexec](#setup-sockexec)
  + [Setup Authentication Server](#setup-authentication-server)
  + [Clone and setup](#clone-and-setup)
  + [Install Lua modules](#install-lua-modules)
  + [Initialize the database](#initialize-the-database)
* [Usage](#usage)
  + [Start the server](#start-the-server)
  + [Alternative: run as systemd service](#alternative-run-as-systemd-service)
  + [Web Usage](#web-usage)
  + [IRC Usage](#irc-usage)
* [Reference](#reference)
  + [`bin/multistreamer` usage:](#binmultistreamer-usage)
  + [Alternative install options:](#alternative-install-options)
    - [Remove Bash dependency](#remove-bash-dependency)
* [Roadmap](#roadmap)
* [Versioning](#versioning)
* [Licensing](#licensing)

## Requirements

* [OpenResty](https://openresty.org/en/) with some extra modules:
  * [nginx-rtmp-module](https://github.com/arut/nginx-rtmp-module)
  * [stream-lua-nginx-module](https://github.com/openresty/stream-lua-nginx-module)
* ffmpeg
* lua 5.1
* luarocks
* luajit (included with OpenResty)
* a POSIX shell (bash, ash, dash, etc)

Note you specifically need OpenResty for this. I no longer support or recommend
compiling a custom Nginx with the Lua module, you'll need the OpenResty
distribution, which includes Lua modules like `lua-resty-websocket`,
`lua-resty-redis`, `lua-resty-lock`, and so on.

## Installation

### Install with Docker

I have a Docker image available, along with a docker-compose file for
quickly getting up and running. Instructions are available here:
https://github.com/jprjr/docker-multistreamer

### Install OpenResty with `setup-openresty`

I've written a script for setting up OpenResty and LuaRocks: https://github.com/jprjr/setup-openresty

This is now my preferred way for setting up OpenResty. It automatically
installs build pre-requisites for a good number of distros, and installs
Lua 5.1.5 in addition to LuaJIT. This allows LuaRocks to build C modules
that no longer build against LuaJIT (like cjson).

To install, simply:

```bash
git clone https://github.com/jprjr/setup-openresty
cd setup-openresty
sudo ./setup-openresty
  --prefix=/opt/openresty-rtmp \
  --with-rtmp \
  --with-stream \
  --with-stream-ssl \
  --with-stream-lua
```

### Alternative: Install OpenResty with RTMP Manually

You'll want to install Lua 5.1.5 as well, so that LuaRocks can build older
C modules. I have a patch in this repo for building `liblua` as a dynamic
library, just in case some C module tries to link against `liblua` for
some reason.

```bash
sudo apt-get -y install \
  libreadline-dev \
  libncurses5-dev \
  libpcre3-dev \
  libssl-dev \
  perl \
  make \
  build-essential \
  unzip \
  curl \
  git
mkdir openresty-build && cd openresty-build
curl -R -L https://openresty.org/download/openresty-1.11.2.5.tar.gz | tar xz
curl -R -L https://github.com/arut/nginx-rtmp-module/archive/v1.2.0.tar.gz | tar xz
curl -R -L https://github.com/openresty/stream-lua-nginx-module/archive/a3a050bfacfb8d097ee276380c4e606031f2aaf2.tar.gz | tar xz
curl -R -L http://luarocks.github.io/luarocks/releases/luarocks-2.4.2.tar.gz | tar xz
curl -R -L https://www.lua.org/ftp/lua-5.1.5.tar.gz | tar xz

cd openresty-1.11.2.5
./configure \
  --prefix=/opt/openresty-rtmp \
  --with-pcre-jit \
  --with-ipv6 \
  --with-stream \
  --with-stream_ssl_module \
  --add-module=../nginx-rtmp-module-1.2.0 \
  --add-module=../stream-lua-nginx-module-a3a050bfacfb8d097ee276380c4e606031f2aaf2
make
sudo make install

cd ../lua-5.1.5
patch -p1 < /path/to/lua-5.1.5.patch # in this repo under misc
sed -e 's,/usr/local,/opt/openresty-rtmp,g' -i src/luaconf.h
make CFLAGS="-fPIC -O2 -Wall -DLUA_USE_LINUX" linux
sudo make INSTALL_TOP="/opt/openresty-rtmp/luajit" TO_LIB="liblua.a liblua.so" install

cd ../luarocks-2.4.2
./configure \
  --prefix=/opt/openresty-rtmp \
  --with-lua=/opt/openresty-rtmp/luajit \
  --rocks-tree=/opt/openresty-rtmp/luajit
make build
sudo make bootstrap
```

### Setup database and user in Postgres

Change your user/password/database names to whatever you want.

Editing `pg_hba.conf` for network access is outside the scope of
this `README` file.

```bash
sudo su - postgres
psql
postgres=# create user multistreamer with password 'multistreamer';
postgres=# create database multistreamer with owner multistreamer;
postgres=# \q
```

### Setup Redis

I'm not going to write up instructions for setting up Redis - this is more
of a checklist item.

### Setup Sockexec

`multistreamer` uses the `lua-resty-exec` module for managing ffmpeg processes,
which requires a running instance of [`sockexec`](https://github.com/jprjr/sockexec).
The `sockexec` repo has instructions for installation - you can either compile from
source, or just download a static binary.

Make sure you change `sockexec`'s default timeout value. The default is pretty
conservative (60 seconds). I'd recommend making it infinite (ie, `sockexec -t0 /tmp/exec.sock`).

### Setup Authentication Server

`multistreamer` doesn't handle its own authentication - instead, it will
make an authenticated HTTP/HTTPS request to some server and allow/deny user
logins based on that.

You can make a really simple htpasswd-based server with nginx:

```nginx
worker_processes 1;
error_log stderr notice;
pid logs/nginx.pid;
daemon off;

events {
  worker_connections 1024;
}

http {
  access_log off;
  server {
    listen 127.0.0.1:8080;
    root /dev/null;
    location / {
      auth_basic "default";
      auth_basic_user_file "/path/to/htpasswd/file";
      try_files $uri @auth;
    }
    location @auth {
      return 204;
    }
  }
}
```

I have some some projects for quickly setting up authentication servers:

* htpasswd: https://github.com/jprjr/htpasswd-auth-server
* LDAP: https://github.com/jprjr/ldap-auth-server


### Clone and setup

Clone this repo somewhere, copy the example config file, and edit it as-needed

```bash
git clone https://github.com/jprjr/multistreamer.git
cd multistreamer
cp config.lua.example config.lua
# edit config.lua
```

I've tried to comment `config.lua.example` and describe what each setting
does as best as I can.

The config file allows storing multiple environments in a single file,
see http://leafo.net/lapis/reference/configuration.html for details.

One of the more important items in the config file is the `networks` section,
right now the supported networks are:

* `facebook` - supports profiles and pages, auto-creates live video, pushes video.
* `rtmp` - just push video to an RTMP URL
* `twitch` - supports editing/updating channel information and pushing video
* `youtube` - auto-creates live "events" and pushes video

Each module has more details in the [wiki.](https://github.com/jprjr/multistreamer/wiki)

### Install Lua modules

You'll need some Lua modules installed:

* lua-resty-exec
* lua-resty-jit-uuid
* lua-resty-http
* lapis
* etlua
* luaposix
* luafilesystem
* whereami

#### Installing locally

If you install modules to a folder named `lua_modules`, the  bash script (`./bin/multistreamer`)
setup nginx/Lua to only use that folder. So, assuming you're still in
the `multistreamer` folder:

```bash
/opt/openresty-rtmp/bin/luarocks install --tree=lua_modules --only-deps rockspecs/multistreamer-dev-1.rockspec
```


**Note**: older verions of LuaRocks might not automatically install dependencies.
Here's the full list of modules, including dependencies:

```
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install bit32
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install lua-cjson
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install date
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install luacrypto
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install ansicolors
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install lpeg
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install etlua
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install loadkit
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install luafilesystem
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install mimetypes
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install luasocket
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install luabitop
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install pgmoon
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install netstring
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install lua-resty-exec
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install lua-resty-jit-uuid
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install lua-resty-http
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install lapis
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install etlua
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install luaposix
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install luafilesystem
/opt/openresty-rtmp/bin/luarocks --tree=lua_modules install whereami
```

Using Mac OS? `lapis` will probably fail to install because `luacrypto`
will fail to build. If you're using Homebrew, you can install
`luacrypto` with:

`luarocks --tree lua_modules install luacrypto OPENSSL_DIR=/usr/local/opt/openssl`

Then proceed to install `lapis`.

### Initialize the database

If you run `./bin/multistreamer -e <environment> initdb`, a new database will
be created.

Alternatively, you could run something like:

`psql -U <username> -h <host> -f sql/1477785578.sql`

### Customization

Starting with Multistreamer 6.0.0, you can override CSS and images.

Just copy the `static` folder to `local`, then edit/replace files as needed.

## Usage

### Start the server

Once it's been setup, you can start the server with `./bin/multistreamer -e <environment> run`

### Alternative: run as systemd service

First, create a local user to run `multistreamer` as:

```bash
sudo useradd \
  -d /var/lib/multistreamer -m \
  -r \
  -s /usr/sbin/nologin \
  multistreamer
```

Then copy `misc/multistreamer.service` to
`/etc/systemd/system/multistreamer.service`, and edit it as-needed - you'll
probably need to change the `ExecStart` line to point to wherever you
cloned the git repo.

### Web Usage

The web interface has two fundamental concepts: "Accounts" and "Streams."

A user is able to add Accounts to their profile (like a Twitch account or
Facebook Account). The user is also able to create Streams, which generates a
stream key for the user.

Once a stream is created and an account added, the user can start associating
accounts with streams. An account can be used on as many different streams
as the user would like.

Each stream has its own set of metadata, like a title for the broadcast, the
game being played, and so on. From one page, the user can setup multiple
account's metadata. Each account has their own set of fields, so the user
can customize the title, description, and so-on for each service.

It's important to note that updating the web interface does *not* immediately
change anything on the user's streaming services - it's saved for later,
when the user starts pushing video.

The user can setup a stream to either start pushing video to their streaming
services as soon as an incoming video stream is detected, or to wait until
they've had a chance to preview the stream. Either way, `multistreamer` will
update each account as needed just before it starts pushing video out - things
like updating the Twitch's broadcast title and game, or make a new Live Video
for Facebook.

Once the user stops pushing video, `multistreamer` will take any needed
shutdown/stop actions - like ending the Facebook Live Video.

I highly recommend that users browse the
[Wiki](https://github.com/jprjr/multistreamer/wiki) - I tried to detail
each section of the web interface, all the different metadata fields
of the different network modules, etc.

### IRC Usage

Users can connect to Multistreamer with an IRC client, and view their
stream's comments and messages.

The IRC interface supports logging in with SASL PLAIN authentication, as
well as by specifying a server password. Both of these methods transmit
the password in plain-text, so you should place some kind
of SSL terminator in front of Multistreamer, like stunnel or haproxy.

Once a user has logged into the IRC interface, they'll see a list of rooms
representing all user's streams on the system. The room names
use the format `(username)-(streamname)`

Whenever a stream goes live, an IRC bot will join the room - this bot represents
an actual account being streamed to. It's username will use the format
`(network-name)-(account-name)`.

Whenever a new comment/chat/etc comes in, the bot will relay it to the room,
with the format `(username)-(network-name) (message)`

I can post messages/comments to my streams by addressing the bots.

When the stream ends, the bots will leave the room.

Attached is a screenshot of Adium. I'm the user `john`, and my stream is named
`Awesome`, so I'm in the room `#john-awesome`

![screenshot](misc/irc-screenshot.png)

## Reference

### `bin/multistreamer` usage:

Here's the full list of options for `multistreamer`:

```
multistreamer [-h] [-l /path/to/lua] -e <environment> <action>
```

* `-h` - displays help
* `-l /path/to/lua` - explicitly provide a path to the lua/luajit binary
* `-e <environment>` - one of the environments defined in `config.lua`
* `<action>` - can be one of
  * `run` - launches nginx
  * `initdb` - initialized the database
  * `psql` - starts up a psql session for your environment
  * `live <uuid>` - **internal**, the rtmp module calls this to setup
    and run ffmpeg.


### Alternative install options:

#### Remove Bash dependency

The bash script at `bin/multistreamer` sets a few environment variables
before calling `bin/multistreamer.lua`, and attempts to figure out which
`lua` implementation to use.

If you can't or don't want to use bash you can call `bin/multistreamer.lua` - just
be sure to set the following environment variables:

* `LAPIS_ENVIRONMENT` - required
* `LUA_PACKAGE_PATH` - optional
* `LUA_PACKAGE_CPATH` - optional

## Roadmap

New features I'd like to work on:

* More networks!

## Versioning

This project uses semantic versioning: `MAJOR.MINOR.PATCH`

A change to the major release number means the user *must* make a
configuration change, running a database migration, etc. Upgrading
to a new major release without taking action *will* result in a failure.

A change to the minor release number means some new feature is available,
but the user doesn't necessarily need to take action (though the new
feature might be disabled until they make a config change etc).

A change to the patch number means I've made some small bug fix.

All releases will include notes with details on migrating databases,
updating the config, and so on.

## Licensing

This project is licensed under the MIT license, see the file `LICENSE`
for more details. This license applies to all files, except the
following exceptions:

This project includes a copy of Pure.css (`static/css/pure-min.css`),
which is licensed under a BSD-style license. Pure.css license is available
as LICENSE-purecss.

This project includes a copy of commonmark.js (`static/js/commonmark.min.js`),
which is licensed under a BSD-style licnese. The commonmark.js license is
available as LICENSE-commonmark-js

This project includes a copy of lua-resty-redis (`resty/redis.lua`),
which is licensed under a BSD license. The license for lua-resty-redis is
available as LICENSE-lua-resty-redis

This project includes a copy of lua-resty-websocket (`resty/websocket/protocol.lua`,
`resty/websocket/client.lua`, `resty/websocket/server.lua`) which is license under
a BSD license. The license for lua-resty-websocket is available as
LICENSE-lua-resty-websocket.

This project includes a copy of zenscroll (`static/js/zenscroll-min.js`), which
is public-domain code. The license for zenscroll is availble as LICENSE-zenscroll.

The network modules for Facebook, Twitch, and YouTube include embedded SVG icons from
[simpleicons.org](https://simpleicons.org/). These icons are in the public domain
see [https://github.com/danleech/simple-icons/blob/gh-pages/LICENSE.md](https://github.com/danleech/simple-icons/blob/gh-pages/LICENSE.md).
I'll be honest, I'm not sure how trademark law applies here (but I'm sure it does),
so I feel obligated to mention that all trademarked images are property of their
respective companies.

The network module for Mixer uses an embedded SVG icon from [mixer-branding-kit](https://github.com/mixer/branding-kit),
it is property of [Mixer](https://mixer.com).
