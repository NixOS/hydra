#!/bin/sh

initdb ./.hydra-data/postgres
exec postgres -D ./.hydra-data/postgres -k $(pwd)/.hydra-data/postgres -p ${PGPORT}
