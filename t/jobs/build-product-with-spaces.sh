#! /bin/sh

mkdir -p $out/nix-support
echo "Hello" > "$out/some text.txt"
echo "doc none \"$out/some text.txt\"" > $out/nix-support/hydra-build-products
