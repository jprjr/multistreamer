# multistreamer

This is a tool for simulcasting RTMP streams to multiple services.

It allows users to add accounts for their favorite streaming services,
and gives an endpoint for them to push video to. Their video stream will
be relayed to multiple accounts.

It also allows for updating their stream's metadata (stream title,
description, etc) from a single page, instead of logging into multiple
services.

Additionally, it provides an IRC interface, where users can read/write
comments and messages in a single location. Please see the
[wiki](https://github.com/jprjr/multistreamer/wiki) for
details on which services support which features.

Fun, unintentional side effect: you can use this to push video to your
personal Facebook profile, instead of using the phone app. This isn't
available via the regular Facebook web interface, as far as I know. :)

Please note: you're responsible for ensuring you're not violating each
service's Terms of Service via simulcasting.

I have a YouTube video with an overview here: https://youtu.be/rjaTaHm4WkA

## Table of Contents

* [Requirements](#requirements)
* [Installation](#installation)
  + [Install OpenResty with RTMP](#install-openresty-with-rtmp)
  + [Alternative: Install nginx with Lua and rtmp](#alternative-install-nginx-with-lua-and-rtmp)
  + [Setup database and user in Postgres](#setup-database-and-user-in-postgres)
  + [Setup Redis](#setup-redis)
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

* nginx/OpenResty with some modules:
  * [nginx-rtmp-module](https://github.com/arut/nginx-rtmp-module)
  * [lua-nginx-module](https://github.com/openresty/lua-nginx-module)
  * [stream-lua-nginx-module](https://github.com/openresty/stream-lua-nginx-module)
  * note: the default OpenResty bundle does not include the rtmp module or the
    TCP lua module - these can be be added with `--add-module`, see
    [http://openresty.org/en/installation.html](http://openresty.org/en/installation.html)
* ffmpeg
* lua or luajit and luarocks
* (optional) bash

## Installation

### Install OpenResty with RTMP

You don't explicitly need OpenResty - it's just convenient because it already
includes the Lua module (and the Lua module's requirements).

```bash
mkdir openresty-build && cd openresty-build
curl -R -L https://openresty.org/download/openresty-1.11.2.2.tar.gz | tar xz
curl -R -L https://github.com/arut/nginx-rtmp-module/archive/v1.1.10.tar.gz | tar xz
curl -R -L https://github.com/openresty/stream-lua-nginx-module/archive/e527417c5d04da0c26c12cf4d8a0ef0f1e36e051.tar.gz | tar xz
cd openresty-1.11.2.2
./configure \
  --prefix=/opt/openresty-rtmp \
  --with-stream \
  --with-stream_ssl_module \
  --add-module=../nginx-rtmp-module-1.1.10 \
  --add-module=../stream-lua-nginx-module-e527417c5d04da0c26c12cf4d8a0ef0f1e36e051
make
sudo make install
```

### Alternative: Install nginx with Lua and rtmp

Here's a short script to download nginx and install it to `/opt/nginx-rtmp`

```bash
mkdir nginx-build && cd nginx-build
curl -R -L http://nginx.org/download/nginx-1.10.2.tar.gz | tar xz
curl -R -L https://github.com/simpl/ngx_devel_kit/archive/v0.3.0.tar.gz | tar xz
curl -R -L https://github.com/openresty/lua-nginx-module/archive/v0.10.7.tar.gz | tar xz
curl -R -L https://github.com/arut/nginx-rtmp-module/archive/v1.1.10.tar.gz | tar xz
curl -R -L https://github.com/openresty/stream-lua-nginx-module/archive/e527417c5d04da0c26c12cf4d8a0ef0f1e36e051.tar.gz | tar xz
cd nginx-1.10.2
export LUAJIT_LIB=$(pkg-config --variable=libdir luajit)
export LUAJIT_INC=$(pkg-config --variable=includedir luajit)
./configure \
  --prefix=/opt/nginx-rtmp \
  --with-threads \
  --with-file-aio \
  --with-ipv6 \
  --with-http_ssl_module \
  --with-pcre \
  --with-pcre-jit \
  --with-stream \
  --with-stream_ssl_module \
  --add-module=../ngx_devel_kit-0.3.0 \
  --add-module=../lua-nginx-module-0.10.7 \
  --add-module=../nginx-rtmp-module-1.1.10 \
  --add-module=../stream-lua-nginx-module-e527417c5d04da0c26c12cf4d8a0ef0f1e36e051
make
sudo make install
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

* lua-resty-jit-uuid
* lua-resty-string
* lua-resty-http
* lua-resty-upload
* lapis
* etlua
* luaposix
* luafilesystem
* whereami


If you install modules to a folder named `lua_modules`, the  bash script will
setup nginx/Lua to only use that folder. So, assuming you're still in
the `multistreamer` folder:

```bash
luarocks --tree lua_modules install lua-resty-jit-uuid
luarocks --tree lua_modules install lua-resty-string
luarocks --tree lua_modules install lua-resty-http
luarocks --tree lua_modules install lua-resty-upload
luarocks --tree lua_modules install lapis
luarocks --tree lua_modules install etlua
luarocks --tree lua_modules install luaposix
luarocks --tree lua_modules install luafilesystem
luarocks --tree lua_modules install whereami
```

Note: `whereami` may give you a hard time if you don't have
`luarocks-fetch-gitrec` installed globally.

Make sure your luarocks is setup for Lua 5.1 and/or LuaJIT.

Using Mac OS? `lapis` will probably fail to install because `luacrypto`
will fail to build. If you're using Homebrew, you can install
`luacrypto` with:

`luarocks --tree lua_modules install luacrypto OPENSSL_DIR=/usr/local/opt/openssl`

Then proceed to install lapis.

### Initialize the database

If you run `./bin/multistreamer -e <environment> initdb`, a new database will
be created.

Alternatively, you could run something like:

`psql -U <username> -h <host> -f sql/1477785578.sql`

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

When the user starts pushing video to the RTMP endpoint, `multistreamer` will
update each account as needed - like updating the Twitch's broadcast title
and game, or make a new Live Video for Facebook. It will then start relaying
video to the different accounts.

Once the user stops pushing video, `multistreamer` will take any needed
shutdown/stop actions - like ending the Facebook Live Video.

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

* A web interface for viewing and responding to chat messages, comments,
etc - basically, a web version of the IRC functionality.
  * Probably a basic page that uses a websocket for sending/receiving
    messages.
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
for more details.

This project includes a copy of Pure.css (`static/css/pure-min.css`),
which is licensed under a BSD-style license. Pure.css license is available
as LICENSE-purecss.

This project includes a copy of lua-resty-redis (`resty/redis.lua`),
which is licensed under a BSD license. The license for lua-resty-redis is
available as LICENSE-lua-resty-redis
