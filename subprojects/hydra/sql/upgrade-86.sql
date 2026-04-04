ALTER TABLE BuildSteps ADD COLUMN resolvedToStep integer;
ALTER TABLE BuildSteps ADD CONSTRAINT buildsteps_resolvedto_fkey
    FOREIGN KEY (build, resolvedToStep)
    REFERENCES BuildSteps(build, stepnr) ON DELETE CASCADE;
