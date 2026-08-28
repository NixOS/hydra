-- The build that performed an evaluation, when evaluation ran as a build.
-- Nullable with no default, so this is a metadata-only change: no table
-- rewrite, and existing evaluations are legitimately null.
ALTER TABLE JobsetEvals ADD COLUMN eval_build integer;

-- `set null`, never cascade: evaluation builds live in a high-churn jobset
-- that is garbage collected aggressively, and losing an evaluation because
-- its evaluator aged out would be far worse than losing the provenance.
ALTER TABLE JobsetEvals
  ADD CONSTRAINT jobsetevals_eval_build_fkey
  FOREIGN KEY (eval_build) REFERENCES Builds(id) ON DELETE SET NULL;

-- Whether a tentative evaluation has been filled in from its build yet. See
-- the comment in hydra.sql for why this cannot be inferred from the other
-- columns. Nullable with no default, so metadata-only like the above: rows
-- that predate evaluation-as-a-build have no eval_build either, and the two
-- nulls together mean "written in one shot, the old way".
ALTER TABLE JobsetEvals ADD COLUMN completed bigint;
