-- Introduce the storeDir columns, but nothing more: no backfill, no
-- constraints, no index churn. Adding a nullable column with no default
-- is a catalog-only change, so this migration is instant on a database
-- of any size and takes no meaningful lock.
--
-- That matters because the actual conversion — stripping the store dir
-- off every store-path column, which rewrites every row of tables that
-- hold hundreds of millions of them — is deliberately *not* done here.
-- Running it inside this migration would mean a single transaction of
-- many hours that starts over from nothing if anything goes wrong. It is
-- instead done by `hydra-backfill-store-dirs`, which works in small
-- committed batches and resumes where it left off.
--
-- While that runs, the two formats coexist and are told apart per row: a
-- not-yet-converted row has a full path and a null storeDir, a converted
-- one has a basename and a store dir. A full path contains a slash and a
-- basename never does, so the discriminator is also visible in the data
-- itself. Hydra reads both formats and writes only the new one, with the
-- exception of content-addressed derivation resolution, which assumes
-- the new format and may simply not find not-yet-converted rows: CA
-- builds are expected to be degraded for the duration.
--
-- Once no null storeDir remains, schema version 90 makes the column
-- mandatory and adds the constraints that tie each row's store dir to
-- its parent's.

ALTER TABLE Builds ADD COLUMN storeDir text;
ALTER TABLE BuildSteps ADD COLUMN storeDir text;
ALTER TABLE BuildOutputs ADD COLUMN storeDir text;
ALTER TABLE BuildStepOutputs ADD COLUMN storeDir text;
ALTER TABLE BuildInputs ADD COLUMN storeDir text;
ALTER TABLE BuildProducts ADD COLUMN storeDir text;
-- `BuildProducts.path` is the one store-path column that can name a path
-- *inside* a store path, e.g. ".../<hash>-foo/share/doc/README". Splitting
-- the store dir off it leaves two things stuck together, so this column takes
-- the sub-path and `path` is left holding a store path like every other.
ALTER TABLE BuildProducts ADD COLUMN subPath text;
ALTER TABLE JobsetEvalInputs ADD COLUMN storeDir text;
ALTER TABLE FailedPaths ADD COLUMN storeDir text;
ALTER TABLE CachedPathInputs ADD COLUMN storeDir text;
ALTER TABLE CachedSubversionInputs ADD COLUMN storeDir text;
ALTER TABLE CachedBazaarInputs ADD COLUMN storeDir text;
ALTER TABLE CachedGitInputs ADD COLUMN storeDir text;
ALTER TABLE CachedDarcsInputs ADD COLUMN storeDir text;
ALTER TABLE CachedHgInputs ADD COLUMN storeDir text;
ALTER TABLE CachedCVSInputs ADD COLUMN storeDir text;
