#!/bin/sh

# wait until hydra is listening on port 3000
while ! nc -z localhost 3000; do sleep 1; done

hydra-queue-runner
