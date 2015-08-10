alter table Builds add column globalPriority integer not null default 0;

create function notifyBuildBumped() returns trigger as 'begin notify builds_bumped; return null; end;' language plpgsql;
create trigger BuildBumped after update on Builds for each row
  when (old.globalPriority != new.globalPriority) execute procedure notifyBuildBumped();
