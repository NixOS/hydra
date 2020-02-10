#!/usr/bin/env bash

readonly scratch=$(mktemp -d -t tmp.XXXXXXXXXX)

readonly socket=$scratch/socket
readonly data=$scratch/data
readonly dbname=hydra-update-dbix

function finish {
    set +e
    pg_ctl -D "$data" \
           -o "-F -h '' -k \"$socket\"" \
           -w stop -m immediate

    if [ -f "$data/postmaster.pid" ]; then
        pg_ctl -D "$data" \
               -o "-F -h '' -k \"$socket\"" \
               -w kill TERM "$(cat "$data/postmaster.pid")"
    fi

    rm -rf "$scratch"
}
trap finish EXIT

set -e

mkdir -p "$socket"
initdb -D "$data"

pg_ctl -D "$data" \
       -o "-F -h '' -k \"${socket}\"" \
       -w start

createdb -h "$socket" "$dbname"

psql -h "$socket" "$dbname" -f ./hydra-postgresql.sql

perl -I ../lib \
     -MDBIx::Class::Schema::Loader=make_schema_at,dump_to_dir:../lib \
     update-dbix.pl "dbi:Pg:dbname=$dbname;host=$socket"
