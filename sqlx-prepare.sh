#!/usr/bin/env bash
set -euo pipefail

set -x

PGDIR=$(mktemp -d)
trap 'pg_ctl -D "$PGDIR" stop -m immediate 2>/dev/null; rm -rf "$PGDIR"' EXIT

initdb -D "$PGDIR" --no-locale -E UTF8
pg_ctl -D "$PGDIR" -l "$PGDIR/log" -o "-k $PGDIR -h ''" start

createdb -h "$PGDIR" hydra
psql -h "$PGDIR" -d hydra -f subprojects/hydra/sql/hydra.sql

# The role initdb created is the OS user; sqlx 0.9 no longer assumes that.
export DATABASE_URL="postgres://$(id -un)@localhost/hydra?host=$PGDIR"

# Note: if something is not regenerating, try:
#
#     cargo clean -p db -p hydra-evaluator

# `--all-targets` so queries in tests are cached too.
# The binary cache's narinfo presence cache is SQLite, so its queries are
# checked against a SQLite database built from the same schema the crate
# creates at runtime; its `sqlx.toml` names the variable this URL goes in.
SQLITE="$PGDIR/presence.sqlite"
python3 -c 'import sqlite3, sys; sqlite3.connect(sys.argv[1]).executescript(open(sys.argv[2]).read())' \
    "$SQLITE" subprojects/crates/binary-cache/src/presence_cache.sql
export PRESENCE_CACHE_DATABASE_URL="sqlite://$SQLITE"

cargo sqlx prepare --workspace -- --all-targets
