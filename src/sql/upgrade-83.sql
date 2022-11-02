ALTER TABLE Jobsets ALTER COLUMN errorTime TYPE BIGINT;
ALTER TABLE Jobsets ALTER COLUMN lastCheckedTime TYPE BIGINT;

DROP TRIGGER IF EXISTS JobsetSchedulingChanged ON Jobsets;
ALTER TABLE Jobsets ALTER COLUMN triggerTime TYPE BIGINT;
create trigger JobsetSchedulingChanged after update on Jobsets for each row
  when (((old.triggerTime is distinct from new.triggerTime) and (new.triggerTime is not null))
        or (old.checkInterval != new.checkInterval)
        or (old.enabled != new.enabled))
  execute procedure notifyJobsetSchedulingChanged();

ALTER TABLE Jobsets ALTER COLUMN startTime TYPE BIGINT;
ALTER TABLE Builds ALTER COLUMN timestamp TYPE BIGINT;
ALTER TABLE Builds ALTER COLUMN startTime TYPE BIGINT;
ALTER TABLE Builds ALTER COLUMN stopTime TYPE BIGINT;
ALTER TABLE BuildSteps ALTER COLUMN startTime TYPE BIGINT;
ALTER TABLE BuildSteps ALTER COLUMN stopTime TYPE BIGINT;
ALTER TABLE BuildMetrics ALTER COLUMN timestamp TYPE BIGINT;
ALTER TABLE CachedPathInputs ALTER COLUMN timestamp TYPE BIGINT;
ALTER TABLE CachedPathInputs ALTER COLUMN lastSeen TYPE BIGINT;
ALTER TABLE CachedCVSInputs ALTER COLUMN timestamp TYPE BIGINT;
ALTER TABLE CachedCVSInputs ALTER COLUMN lastSeen TYPE BIGINT;
ALTER TABLE EvaluationErrors ALTER COLUMN errorTime TYPE BIGINT;
ALTER TABLE JobsetEvals ALTER COLUMN timestamp TYPE BIGINT;
ALTER TABLE NewsItems ALTER COLUMN createTime TYPE BIGINT;
ALTER TABLE RunCommandLogs ALTER COLUMN start_time TYPE BIGINT;
ALTER TABLE RunCommandLogs ALTER COLUMN end_time TYPE BIGINT;
