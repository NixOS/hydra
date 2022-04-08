alter table Jobsets add column flakeattr text;
alter table JobsetEvals add column flakeattr text;

alter table Jobsets drop constraint if exists jobsets_legacy_paths_check;
alter table Jobsets add constraint jobsets_legacy_paths_check check ((type = 0) = (nixExprInput is not null and nixExprPath is not null and flake is null and flakeattr is null));
