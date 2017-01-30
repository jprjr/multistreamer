create table if not exists shared_streams (
  user_id integer references users(id),
  stream_id integer references streams(id),
  chat_level integer default 0,
  metadata_level integer default 0,
  created_at timestamp without time zone NOT NULL,
  updated_at timestamp without time zone NOT NULL,
  primary key(user_id,stream_id)
);

