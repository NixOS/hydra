# Hydra SQL Schema and Migrations

## Directory layout

- `hydra.sql` — the current schema, used for fresh installs

- `migrations/upgrade-<n>.sql` — incremental migrations from version N-1 to N

- `schemas/hydra-<n>.sql` — historical snapshot of `hydra.sql` at version N

- `schemas/commit-<n>.txt` — the git commit each snapshot was extracted from

- `check-migrations.nix` — Nix derivations that test each migration step

## Making a schema change

1. Update `hydra.sql` to reflect the desired end state.

2. Create `migrations/upgrade-<n>.sql` with the migration SQL.

3. Copy `hydra.sql` to `schemas/hydra-<n>.sql`.

4. Run the migration check to verify:

   ```
   nix-build -A checks.x86_64-linux.migration-M-to-N
   ```

   where M = N-1.

5. Commit changes.

6. Create `schemas/commit-<n>.txt` with the new commit hash.

7. Verify the snapshot matches the commit:

   ```
   ./schemas/verify.sh
   ```

   (Note, this requires a full git history, not just the latest tree, so we
   don't bother putting it inside a formal nix derivation check.)
