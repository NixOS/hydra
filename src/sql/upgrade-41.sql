create function notifyJobsetSharesChanged() returns trigger as 'begin notify jobset_shares_changed; return null; end;' language plpgsql;
create trigger JobsetSharesChanged after update on Jobsets for each row
  when (old.schedulingShares != new.schedulingShares) execute procedure notifyJobsetSharesChanged();

update Jobsets set schedulingShares = 1 where schedulingShares <= 0;
alter table Jobsets add constraint jobsets_check check (schedulingShares > 0);
