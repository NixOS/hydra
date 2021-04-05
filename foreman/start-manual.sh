#!/bin/sh

mdbook serve \
  --port 63332 \
  --dest-dir $(pwd)/.hydra-data/manual \
  $(pwd)/doc/manual/
