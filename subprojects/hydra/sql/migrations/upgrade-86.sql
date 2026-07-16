-- drvPath should always have been NOT NULL, and no current code path
-- creates a step without one. However, very old deployments (e.g.
-- hydra.nixos.org) still carry a handful of 2015-era substitution steps
-- whose drvPath was never recorded. Backfill those with a unique,
-- obviously-fake placeholder so the constraint can be enforced; the
-- all-zero hash cannot collide with a real store path, and (build,
-- stepnr) is the primary key, so the placeholders are unique per row.
--
-- Only substitution steps (type = 1) are backfilled: a *build* step
-- with a NULL drvPath would be genuinely unexpected, so the SET NOT
-- NULL below should still abort on one, prompting investigation
-- rather than papering over it.
UPDATE BuildSteps
    SET drvPath = format('/nix/store/00000000000000000000000000000000-unknown-build-%s-step-%s.drv', build, stepnr)
    WHERE drvPath IS NULL
    AND type = 1;

ALTER TABLE BuildSteps ALTER COLUMN drvPath SET NOT NULL;
