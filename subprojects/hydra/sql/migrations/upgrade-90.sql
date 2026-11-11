-- Close out the store-dir conversion begun in schema version 89: now
-- that every store-path column holds a basename and every storeDir is
-- filled in, make that a rule rather than a convention.
--
-- This assumes `hydra-backfill-store-dirs` has finished. Rather than let
-- the NOT NULLs below fail with an error that says nothing about why,
-- check up front and say what to run.

DO $$
DECLARE
    t text;
    pending integer;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'builds', 'buildsteps', 'buildoutputs', 'buildstepoutputs',
        'buildinputs', 'buildproducts', 'jobsetevalinputs', 'failedpaths',
        'cachedpathinputs', 'cachedsubversioninputs', 'cachedbazaarinputs',
        'cachedgitinputs', 'cacheddarcsinputs', 'cachedhginputs',
        'cachedcvsinputs'
    ] LOOP
        -- The path columns that may be null are null exactly when their
        -- storeDir is, so a row pending conversion is one with a path
        -- but no store dir.
        EXECUTE format(
            'SELECT 1 FROM %I WHERE storeDir IS NULL AND %s IS NOT NULL LIMIT 1',
            t,
            CASE WHEN t IN ('builds', 'buildsteps') THEN 'drvPath'
                 WHEN t LIKE 'cached%' THEN 'storePath'
                 ELSE 'path' END)
        INTO pending;
        -- Not `FOUND`: `EXECUTE` leaves that alone, so it would never fire.
        IF pending IS NOT NULL THEN
            RAISE EXCEPTION
                'Table % still has store paths to convert. Run hydra-backfill-store-dirs to completion before upgrading to schema version 90.', t;
        END IF;
    END LOOP;
END$$;

ALTER TABLE Builds ALTER COLUMN storeDir SET NOT NULL;
-- Referenced by the composite foreign keys of the child tables below, so
-- that their storeDir provably agrees with the build's.
ALTER TABLE Builds ADD UNIQUE (storeDir, id);

-- storeDir also covers resolvedDrvPath, which is a basename in the same
-- store (resolution never crosses stores).
ALTER TABLE BuildSteps ALTER COLUMN storeDir SET NOT NULL;
ALTER TABLE BuildSteps ADD UNIQUE (storeDir, build, stepnr);
-- A step builds in its build's store; this composite foreign key both
-- enforces that and subsumes the old single-column one.
ALTER TABLE BuildSteps DROP CONSTRAINT buildsteps_build_fkey;
ALTER TABLE BuildSteps ADD FOREIGN KEY (storeDir, build)
    REFERENCES Builds(storeDir, id) ON DELETE CASCADE;

-- Where the path is nullable the store dir is too, and they are set
-- together. A null store dir also trivially satisfies the composite
-- foreign key, which is why the single-column one stays: without it
-- those rows would no longer cascade on delete.
ALTER TABLE BuildOutputs ADD CHECK ((path IS NULL) = (storeDir IS NULL));
ALTER TABLE BuildOutputs ADD FOREIGN KEY (storeDir, build)
    REFERENCES Builds(storeDir, id) ON DELETE CASCADE;

ALTER TABLE BuildStepOutputs ADD CHECK ((path IS NULL) = (storeDir IS NULL));
ALTER TABLE BuildStepOutputs ADD FOREIGN KEY (storeDir, build, stepnr)
    REFERENCES BuildSteps(storeDir, build, stepnr) ON DELETE CASCADE;

ALTER TABLE BuildProducts ADD CHECK ((path IS NULL) = (storeDir IS NULL));
ALTER TABLE BuildProducts ADD CHECK ((path IS NULL) = (subPath IS NULL));
ALTER TABLE BuildProducts ADD FOREIGN KEY (storeDir, build)
    REFERENCES Builds(storeDir, id) ON DELETE CASCADE;

ALTER TABLE BuildInputs ADD CHECK ((path IS NULL) = (storeDir IS NULL));
ALTER TABLE JobsetEvalInputs ADD CHECK ((path IS NULL) = (storeDir IS NULL));

-- The primary key stays on the bare path (see hydra.sql for why that is
-- sound); this spells out the pair as well.
ALTER TABLE FailedPaths ALTER COLUMN storeDir SET NOT NULL;
ALTER TABLE FailedPaths ADD UNIQUE (storeDir, path);

ALTER TABLE CachedPathInputs ALTER COLUMN storeDir SET NOT NULL;
ALTER TABLE CachedSubversionInputs ALTER COLUMN storeDir SET NOT NULL;
ALTER TABLE CachedBazaarInputs ALTER COLUMN storeDir SET NOT NULL;
ALTER TABLE CachedGitInputs ALTER COLUMN storeDir SET NOT NULL;
ALTER TABLE CachedDarcsInputs ALTER COLUMN storeDir SET NOT NULL;
ALTER TABLE CachedHgInputs ALTER COLUMN storeDir SET NOT NULL;
ALTER TABLE CachedCVSInputs ALTER COLUMN storeDir SET NOT NULL;
