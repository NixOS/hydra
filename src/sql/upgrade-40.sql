UPDATE Builds
SET
  project = j.project,
  jobset = j.name
FROM Jobsets j
WHERE Builds.jobset_id = j.id;

ALTER TABLE Builds ALTER COLUMN project SET NOT NULL;
ALTER TABLE Builds ALTER COLUMN jobset SET NOT NULL;