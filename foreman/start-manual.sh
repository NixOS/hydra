#!/bin/sh

exec mdbook serve \
  --port 63332 \
  --dest-dir ./.hydra-data/manual \
  ./subprojects/hydra-manual/
