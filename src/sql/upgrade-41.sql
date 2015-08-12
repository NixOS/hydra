create function notifyJobsetSharesChanged() returns trigger as 'begin notify jobset_shares_changed; return null; end;' language plpgsql;
create trigger JobsetSharesChanged after update on Jobsets for each row
  when (old.schedulingShares != new.schedulingShares) execute procedure notifyJobsetSharesChanged();

alter table Jobsets add constraint jobsets_check check (schedulingShares > 0);
