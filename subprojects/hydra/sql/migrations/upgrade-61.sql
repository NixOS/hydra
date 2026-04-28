-- Add the jobset_id columns to the Builds table. This will go
-- quickly, since the field is nullable. Note this is just part one of
-- this migration. Future steps involve a piecemeal backfilling, and
-- then making the column non-null.

ALTER TABLE Builds
  ADD COLUMN jobset_id integer NULL,
  ADD FOREIGN KEY (jobset_id)
      REFERENCES Jobsets(id)
      ON DELETE CASCADE;
