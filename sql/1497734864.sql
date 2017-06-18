create table if not exists webhooks (
  id serial,
  stream_id integer references streams(id),
  url text,
  params text,
  notes text,
  type varchar(255),
  created_at timestamp without time zone not null,
  updated_at timestamp without time zone not null,
  primary key(id)
);

