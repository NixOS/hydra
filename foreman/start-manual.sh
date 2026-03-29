#!/bin/sh

mdbook serve \
  --port 63332 \
  --dest-dir ./.hydra-data/manual \
  ./subprojects/hydra-manual/
