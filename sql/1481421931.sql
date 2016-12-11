alter table accounts add column slug varchar(255);
update accounts set slug=regexp_replace(replace(lower(name),' ','-'),'[^a-z0-9\-]','','g') where slug is null;
alter table accounts alter column slug set not null;

