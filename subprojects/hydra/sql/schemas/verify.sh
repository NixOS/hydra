#!/usr/bin/env bash
# Verify that each hydra-N.sql matches the hydra.sql from the commit recorded in commit-N.txt.
# Must be run from a git checkout with full history.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

failures=0
checked=0

# Check for schemas without commits
for schema_file in hydra-*.sql; do
  n="${schema_file#hydra-}"
  n="${n%.sql}"
  if [ ! -f "commit-${n}.txt" ]; then
    echo "ORPHAN SCHEMA: $schema_file has no commit-${n}.txt"
    failures=$((failures + 1))
  fi
done

# The newest version's schema is hydra.sql itself, so its commit-N.txt has no
# vendored hydra-N.sql; the snapshot is only vendored once a newer migration
# supersedes it.
max_commit=0
for commit_file in commit-*.txt; do
  n="${commit_file#commit-}"
  n="${n%.txt}"
  (( n > max_commit )) && max_commit=$n
done

# Check for commits without schemas
for commit_file in commit-*.txt; do
  n="${commit_file#commit-}"
  n="${n%.txt}"
  if [ ! -f "hydra-${n}.sql" ] && [ "$n" != "$max_commit" ]; then
    echo "ORPHAN COMMIT: $commit_file has no hydra-${n}.sql"
    failures=$((failures + 1))
  fi
done

# Verify each commit/schema pair
for commit_file in commit-*.txt; do
  n="${commit_file#commit-}"
  n="${n%.txt}"
  commit="$(grep -v '^#' "$commit_file" | head -1)"
  schema_file="hydra-${n}.sql"

  if [ ! -f "$schema_file" ]; then
    if [ "$n" = "$max_commit" ]; then
      # Newest version: verify the live hydra.sql against the recorded commit.
      schema_file="../hydra.sql"
    else
      continue  # already reported above
    fi
  fi

  # Find hydra.sql in the commit tree (search from repo root)
  path="$(git -C "$(git rev-parse --show-toplevel)" ls-tree -r --name-only "$commit" | grep '/hydra\.sql$' || true)"

  if [[ -z "$path" ]]; then
    echo "FAIL: v${n} — could not find hydra.sql in commit ${commit}"
    failures=$((failures + 1))
    continue
  fi

  checked=$((checked + 1))
  if git diff --quiet "${commit}:${path}" -- "$schema_file"; then
    echo "OK: v${n} (${commit})"
  else
    echo "MISMATCH: v${n} (${commit})"
    git diff "${commit}:${path}" -- "$schema_file" | head -30
    echo "..."
    failures=$((failures + 1))
  fi
done

echo ""
echo "Checked $checked schemas, $failures failures."
exit "$failures"
