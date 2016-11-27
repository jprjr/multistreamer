drop table if exists roles;
create table if not exists roles (
  id serial,
  name varchar(255) not null,
  primary key(id)
);

insert into roles (id, name) values (1,'none');
insert into roles (id, name) values (2,'stream');
insert into roles (id, name) values (3,'notify');

alter table streams_accounts drop constraint streams_accounts_pkey;
alter table streams_accounts add column role_id integer references roles(id);
update streams_accounts set role_id=2;
alter table streams_accounts alter column role_id set not null;
alter table streams_accounts add primary key(account_id,stream_id,role_id);

alter table keystore add column role_id integer references roles(id);
update streams_accounts set role_id=1 where stream_id is null or account_id is null;
update keystore set role_id=2 where stream_id is not null and account_id is not null;
alter table keystore alter column role_id set not null;

