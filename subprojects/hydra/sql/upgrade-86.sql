ALTER TABLE BuildSteps ADD COLUMN resolvedDrvPath text;
ALTER TABLE BuildSteps ADD CONSTRAINT buildsteps_resolved_consistent
    CHECK ((status = 13) = (resolvedDrvPath IS NOT NULL));
