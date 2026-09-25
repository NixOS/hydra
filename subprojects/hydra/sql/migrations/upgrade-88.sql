-- recreate trigger
DROP TRIGGER IF EXISTS JobsetSchedulingChanged ON Jobsets;
ALTER TABLE Jobsets
  ALTER COLUMN errorTime TYPE bigint,
  ALTER COLUMN lastCheckedTime TYPE bigint,
  ALTER COLUMN triggerTime TYPE bigint,
  ALTER COLUMN startTime TYPE bigint;
create trigger JobsetSchedulingChanged after update on Jobsets for each row
  when (((old.triggerTime is distinct from new.triggerTime) and (new.triggerTime is not null))
        or (old.checkInterval != new.checkInterval)
        or (old.enabled != new.enabled))
  execute procedure notifyJobsetSchedulingChanged();

ALTER TABLE Builds
  ALTER COLUMN timestamp TYPE bigint,
  ALTER COLUMN startTime TYPE bigint,
  ALTER COLUMN stopTime TYPE bigint,
  ALTER COLUMN notificationPendingSince TYPE bigint;

ALTER TABLE BuildSteps
  ALTER COLUMN startTime TYPE bigint,
  ALTER COLUMN stopTime TYPE bigint;

ALTER TABLE BuildMetrics ALTER COLUMN timestamp TYPE bigint;

ALTER TABLE CachedPathInputs
  ALTER COLUMN timestamp TYPE bigint,
  ALTER COLUMN lastSeen TYPE bigint;

ALTER TABLE CachedCVSInputs
  ALTER COLUMN timestamp TYPE bigint,
  ALTER COLUMN lastSeen TYPE bigint;

ALTER TABLE EvaluationErrors ALTER COLUMN errorTime TYPE bigint;

ALTER TABLE JobsetEvals ALTER COLUMN timestamp TYPE bigint;

ALTER TABLE NewsItems ALTER COLUMN createTime TYPE bigint;

ALTER TABLE TaskRetries ALTER COLUMN retry_at TYPE bigint;

ALTER TABLE RunCommandLogs
  ALTER COLUMN start_time TYPE bigint,
  ALTER COLUMN end_time TYPE bigint;
