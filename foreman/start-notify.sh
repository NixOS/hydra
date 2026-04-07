#!/bin/sh

export PATH=$(pwd)/subprojects/hydra/script:$PATH
export PERL5LIB=$(pwd)/subprojects/hydra/lib:$PERL5LIB
export HYDRA_HOME=$(pwd)/subprojects/hydra

export HYDRA_DATA=$(pwd)/.hydra-data
export HYDRA_DBI="dbi:Pg:dbname=hydra;host=localhost;port=64444"

# wait for postgresql and hydra-server
while ! pg_isready -h $(pwd)/.hydra-data/postgres -p 64444; do sleep 1; done
while ! nc -z localhost 63333; do sleep 1; done

HYDRA_CONFIG=$(pwd)/.hydra-data/hydra.conf exec hydra-notify
