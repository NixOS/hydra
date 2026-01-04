ALTER TABLE JobsetEvals
    ADD COLUMN errorMsg text,
    ADD COLUMN errorTime integer NULL;

-- Copy the current error in jobsets to the latest field in jobsetevals
UPDATE jobsetevals
    SET errorMsg = j.errorMsg,
        errorTime = j.errorTime
  FROM (
    SELECT
        jobsets.errorMsg,
        jobsets.errorTime,
        jobsets.id AS jobset_id,
        latesteval.id AS eval_id
    FROM jobsets
    LEFT JOIN
        (
            SELECT
                MAX(id) AS id,
                project,
                jobset
            FROM jobsetevals
            GROUP BY project, jobset
            ORDER BY project, jobset
        )
        AS latesteval
        ON
            jobsets.name = latesteval.jobset
            AND jobsets.project = latesteval.project
    WHERE latesteval.id IS NOT NULL
    ORDER BY jobsets.id
)
AS j
WHERE id = j.eval_id;
