-- CA derivations do not have statically known output paths. The values
-- are only filled in after the build runs.
ALTER TABLE BuildStepOutputs ALTER COLUMN path DROP NOT NULL;
ALTER TABLE BuildOutputs ALTER COLUMN path DROP NOT NULL;
