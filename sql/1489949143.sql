alter table streams add column preview_required integer;
alter table streams add column ffmpeg_pull_args text;
update streams set preview_required = 0 where preview_required is null;
