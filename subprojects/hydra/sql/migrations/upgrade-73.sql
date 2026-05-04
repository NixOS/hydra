create table EvaluationErrors (
    id            serial primary key not null,
    errorMsg      text,    -- error output from the evaluator
    errorTime     integer, -- timestamp associated with errorMsg
    jobsetEvalId  integer not null,

    FOREIGN KEY (jobsetEvalId)
        REFERENCES JobsetEvals(id)
        ON DELETE SET NULL
);

ALTER TABLE JobsetEvals
    ADD COLUMN evaluationerror_id integer NULL,
    ADD FOREIGN KEY (evaluationerror_id)
        REFERENCES EvaluationErrors(id)
        ON DELETE SET NULL;

INSERT INTO EvaluationErrors
    (errorMsg, errorTime, jobsetEvalId)
SELECT errorMsg, errorTime, id
FROM JobsetEvals
WHERE JobsetEvals.errorMsg != '' and JobsetEvals.errorMsg is not null;

UPDATE JobsetEvals
SET evaluationerror_id = EvaluationErrors.id
FROM EvaluationErrors
WHERE JobsetEvals.id = EvaluationErrors.jobsetEvalId
AND JobsetEvals.errorMsg != '' and JobsetEvals.errorMsg is not null;

ALTER TABLE JobsetEvals
    DROP COLUMN errorMsg,
    DROP COLUMN errorTime;

ALTER TABLE EvaluationErrors
    DROP COLUMN jobsetEvalId;
