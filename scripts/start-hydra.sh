#!/bin/sh

# wait for postgresql to listen
while ! nc -z localhost 5432; do sleep 1; done

createdb -h $(pwd)/.hydra-data/postgres hydra

hydra-init
hydra-create-user alice --password foobar --role admin

exec hydra-server
