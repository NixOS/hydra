#!/usr/bin/env bash
set -euo pipefail

set -x

PGDIR=$(mktemp -d)
trap 'pg_ctl -D "$PGDIR" stop -m immediate 2>/dev/null; rm -rf "$PGDIR"' EXIT

initdb -D "$PGDIR" --no-locale -E UTF8
pg_ctl -D "$PGDIR" -l "$PGDIR/log" -o "-k $PGDIR -h ''" start

createdb -h "$PGDIR" hydra
psql -h "$PGDIR" -d hydra -f subprojects/hydra/sql/hydra.sql

export DATABASE_URL="postgres://?host=$PGDIR&dbname=hydra"
#cd subprojects/crates/db
#ln -sfn ../../../.sqlx subprojects/crates/db/.sqlx
cargo sqlx prepare --workspace
