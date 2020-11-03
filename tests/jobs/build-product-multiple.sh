#! /bin/sh
set -eu
mkdir -p $out/nix-support
echo "doc none $not_out" > $out/nix-support/hydra-build-products
