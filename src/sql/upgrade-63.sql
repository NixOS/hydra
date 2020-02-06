-- Make the Jobs.jobset_id column NOT NULL. If this upgrade fails,
-- either the admin didn't run the backfiller or there is a bug. If
-- the admin ran the backfiller and there are null columns, it is
-- very important to figure out where the nullable columns came from.

ALTER TABLE Jobs
  ALTER COLUMN jobset_id SET NOT NULL;
