create table FailedPaths (
    path text primary key not null
);

create rule IdempotentInsert as on insert to FailedPaths
  where exists (select 1 from FailedPaths where path = new.path)
  do instead nothing;
