CREATE EXTENSION pg_trgm;
CREATE INDEX IndexTrgmBuildsOnDrvpath ON builds USING gin (drvpath gin_trgm_ops);
