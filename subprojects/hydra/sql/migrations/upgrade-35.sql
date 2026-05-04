create function notifyBuildsAdded() returns trigger as 'begin notify builds_added; return null; end;' language plpgsql;
create trigger BuildsAdded after insert on Builds execute procedure notifyBuildsAdded();

create function notifyBuildsDeleted() returns trigger as 'begin notify builds_deleted; return null; end;' language plpgsql;
create trigger BuildsDeleted after delete on Builds execute procedure notifyBuildsDeleted();

create function notifyBuildRestarted() returns trigger as 'begin notify builds_restarted; return null; end;' language plpgsql;
create trigger BuildRestarted after update on Builds for each row
  when (old.finished = 1 and new.finished = 0) execute procedure notifyBuildRestarted();

create function notifyBuildCancelled() returns trigger as 'begin notify builds_cancelled; return null; end;' language plpgsql;
create trigger BuildCancelled after update on Builds for each row
  when (old.finished = 0 and new.finished = 1 and new.buildStatus = 4) execute procedure notifyBuildCancelled();
