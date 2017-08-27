create table if not exists lapis_migrations (
  name varchar(255),
  primary key(name)
);

insert into lapis_migrations(name) values('1503806092');

