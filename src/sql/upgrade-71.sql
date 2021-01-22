ALTER TABLE JobsetEvals
    ADD COLUMN nixExprInput text,
    ADD COLUMN nixExprPath text;


-- This migration took 4.5 hours on a server
-- with 5400RPM drives, against a copy of hydra's
-- production dataset. It might take a significantly
-- less amount of time there, and not justify a
-- batched migration.
UPDATE jobsetevals
SET (nixexprinput, nixexprpath) = (
    SELECT builds.nixexprinput, builds.nixexprpath
    FROM builds
    LEFT JOIN jobsetevalmembers
      ON jobsetevalmembers.build = builds.id
    WHERE jobsetevalmembers.eval = jobsetevals.id
    LIMIT 1
)
WHERE jobsetevals.id in (
  SELECT jobsetevalsprime.id
  FROM jobsetevals as jobsetevalsprime
  WHERE jobsetevalsprime.nixexprinput IS NULL
  -- AND jobsetevalsprime.id > ? --------- These are in case of a batched migration
  ORDER BY jobsetevalsprime.id ASC  --  /
  -- LIMIT ?  --  ----------------------
);

ALTER TABLE builds
    DROP COLUMN nixexprinput,
    DROP COLUMN nixexprpath;