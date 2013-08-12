create table NrBuilds (
    what  text primary key not null,
    count integer not null
);

create function modifyNrBuildsFinished() returns trigger as $$
  begin
    if ((tg_op = 'INSERT' and new.finished = 1) or
        (tg_op = 'UPDATE' and old.finished = 0 and new.finished = 1)) then
      update NrBuilds set count = count + 1 where what = 'finished';
    elsif ((tg_op = 'DELETE' and old.finished = 1) or
           (tg_op = 'UPDATE' and old.finished = 1 and new.finished = 0)) then
      update NrBuilds set count = count - 1 where what = 'finished';
    end if;
    return null;
  end;
$$ language plpgsql;

create trigger NrBuildsFinished after insert or update or delete on Builds
  for each row
  execute procedure modifyNrBuildsFinished();

insert into NrBuilds(what, count) select 'finished', count(*) from Builds where finished = 1;
