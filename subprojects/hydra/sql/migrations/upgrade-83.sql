-- This index was introduced in a migration but was never recorded in
-- hydra.sql (the source of truth), which is why `if exists` is required.
drop index if exists IndexBuildOutputsOnPath;
