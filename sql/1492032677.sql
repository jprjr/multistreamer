alter table users add column access_token char(20);
update users
set access_token=substring(upper(md5(random()::text)) from 0 for 21)
where access_token is null;
