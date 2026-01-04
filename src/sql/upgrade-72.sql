
ALTER TABLE JobsetEvals
  ADD COLUMN jobset_id integer NULL,
  ADD FOREIGN KEY (jobset_id)
      REFERENCES Jobsets(id)
      ON DELETE CASCADE;

UPDATE JobsetEvals
  SET jobset_id = (
    SELECT jobsets.id
    FROM jobsets
    WHERE jobsets.name = JobsetEvals.jobset
      AND jobsets.project = JobsetEvals.project
  );


ALTER TABLE JobsetEvals
  ALTER COLUMN jobset_id SET NOT NULL,
  DROP COLUMN jobset,
  DROP COLUMN project;

create index IndexJobsetIdEvals on JobsetEvals(jobset_id) where hasNewBuilds = 1;