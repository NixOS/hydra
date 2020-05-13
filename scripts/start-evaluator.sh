#!/bin/sh

# wait for hydra-server to listen
while ! nc -z localhost 3000; do sleep 1; done

exec hydra-evaluator
