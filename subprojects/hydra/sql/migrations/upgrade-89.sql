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
