-- forward
ALTER TABLE builds ADD COLUMN fodCheck boolean NOT NULL DEFAULT false;

ALTER TABLE buildoutputs ADD COLUMN expectedHash text;
ALTER TABLE buildoutputs ADD COLUMN actualHash text;

ALTER TABLE buildstepoutputs ADD COLUMN expectedHash text;
ALTER TABLE buildstepoutputs ADD COLUMN actualHash text;

-- backwards
-- ALTER TABLE builds DROP COLUMN fodCheck;
--
-- ALTER TABLE buildoutputs DROP COLUMN expectedHash;
-- ALTER TABLE buildoutputs DROP COLUMN actualHash;
--
-- ALTER TABLE buildstepoutputs DROP COLUMN expectedHash;
-- ALTER TABLE buildstepoutputs DROP COLUMN actualHash;
