alter table Jobsets add constraint jobsets_type_known_check   check (type = 0 or type = 1);
alter table Jobsets add constraint jobsets_legacy_paths_check check ((type = 0) = (nixExprInput is not null and nixExprPath is not null and flake is     null));
alter table Jobsets add constraint jobsets_flake_paths_check  check ((type = 1) = (nixExprInput is     null and nixExprPath is     null and flake is not null));
alter table Jobsets add constraint jobsets_schedulingshares_nonzero_check check (schedulingShares > 0);

alter table Jobsets drop constraint if exists jobsets_schedulingshares_check;
alter table Jobsets drop constraint if exists jobsets_check;
alter table Jobsets drop constraint if exists jobsets_check1;
alter table Jobsets drop constraint if exists jobsets_check2;
