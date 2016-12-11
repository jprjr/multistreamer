create table if not exists users (
  id serial,
  username varchar(255) not null,
  created_at timestamp without time zone NOT NULL,
  updated_at timestamp without time zone NOT NULL,
  primary key(id)
);

create table if not exists accounts (
  id serial,
  user_id integer references users(id),
  network varchar(255) not null,
  network_user_id char(40),
  name varchar(255),
  created_at timestamp without time zone NOT NULL,
  updated_at timestamp without time zone NOT NULL,
  primary key(id),
  unique(user_id,network,network_user_id)
);

create table if not exists shared_accounts (
  user_id integer references users(id),
  account_id integer references accounts(id),
  created_at timestamp without time zone NOT NULL,
  updated_at timestamp without time zone NOT NULL,
  primary key(user_id,account_id)
);

create table if not exists streams (
  id serial,
  uuid char(36),
  user_id integer references users(id),
  name varchar(255) not null,
  slug varchar(255) not null,
  created_at timestamp without time zone NOT NULL,
  updated_at timestamp without time zone NOT NULL,
  primary key(id),
  unique(uuid)
);

create table if not exists streams_accounts (
  stream_id integer references streams(id),
  account_id integer references accounts(id),
  rtmp_url text,
  primary key(stream_id,account_id)
);

create table if not exists keystore (
  account_id integer references accounts(id),
  stream_id integer references streams(id),
  key varchar(255) not null,
  value text,
  created_at timestamp without time zone NOT NULL,
  updated_at timestamp without time zone NOT NULL,
  expires_at timestamp without time zone
);

