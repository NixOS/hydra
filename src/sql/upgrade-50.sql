create function notifyJobsetsAdded() returns trigger as 'begin notify jobsets_added; return null; end;' language plpgsql;
create trigger JobsetsAdded after insert on Jobsets execute procedure notifyJobsetsAdded();

create function notifyJobsetsDeleted() returns trigger as 'begin notify jobsets_deleted; return null; end;' language plpgsql;
create trigger JobsetsDeleted after delete on Jobsets execute procedure notifyJobsetsDeleted();

create function notifyJobsetSchedulingChanged() returns trigger as 'begin notify jobset_scheduling_changed; return null; end;' language plpgsql;
create trigger JobsetSchedulingChanged after update on Jobsets for each row
  when ((old.triggerTime is distinct from new.triggerTime) and (new.triggerTime is not null))
        or old.checkInterval != new.checkInterval
        or old.enabled != new.enabled
  execute procedure notifyJobsetSchedulingChanged();
