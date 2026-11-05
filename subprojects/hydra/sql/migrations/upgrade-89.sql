-- Per-phase build timing: store import, build, and upload durations
-- individually instead of only the combined overhead.
ALTER TABLE BuildSteps ADD COLUMN import_time_ms integer;
ALTER TABLE BuildSteps ADD COLUMN build_time_ms integer;
ALTER TABLE BuildSteps ADD COLUMN upload_time_ms integer;
