create extension pg_trgm;
create index IndexTrgmBuildsOnDrvpath on builds using gin (drvpath gin_trgm_ops);
