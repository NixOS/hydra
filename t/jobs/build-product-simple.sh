#! /bin/sh

mkdir -p $out/nix-support
echo "Hello" > $out/text.txt
echo "doc none $out/text.txt" > $out/nix-support/hydra-build-products
