-- We don't know if existing checkouts are deep clones.  This will
-- force a new fetch (and most likely trigger a new build for deep
-- clones, as the binary contents of '.git' are not deterministic).
DELETE FROM CachedGitInputs;

ALTER TABLE CachedGitInputs
    ADD COLUMN isDeepClone BOOLEAN NOT NULL;

ALTER TABLE CachedGitInputs DROP CONSTRAINT cachedgitinputs_pkey;

ALTER TABLE CachedGitInputs ADD CONSTRAINT cachedgitinputs_pkey
    PRIMARY KEY (uri, branch, revision, isDeepClone);
