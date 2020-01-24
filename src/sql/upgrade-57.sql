-- The pg_trgm extension has to be created by a superuser. The NixOS
-- module creates this extension in the systemd prestart script. We
-- then ensure the extension has been created before creating the
-- index. If it is not possible to create the extension, a warning
-- message is emitted to inform the user the index creation is skipped
-- (slower complex queries on builds.drvpath).
do $$
begin
    create extension if not exists pg_trgm;
    -- Provide an index used by LIKE operator on builds.drvpath (search query)
    create index IndexTrgmBuildsOnDrvpath on builds using gin (drvpath gin_trgm_ops);
exception when others then
    raise warning 'Can not create extension pg_trgm: %', SQLERRM;
    raise warning 'HINT: Temporary provide superuser role to your Hydra Postgresql user and run the script src/sql/upgrade-57.sql';
    raise warning 'The pg_trgm index on builds.drvpath has been skipped (slower complex queries on builds.drvpath)';
end$$;
