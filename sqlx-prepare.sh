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
cargo sqlx prepare --workspace -- --all-targets
