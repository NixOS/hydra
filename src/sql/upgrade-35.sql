create function notifyBuildDeleted() returns trigger as $$
  begin
    execute 'notify builds_deleted';
    return null;
  end;
$$ language plpgsql;

create trigger BuildDeleted after delete on Builds
  for each row
  execute procedure notifyBuildDeleted();
