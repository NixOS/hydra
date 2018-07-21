#! /bin/sh

mkdir -p $out/nix-support
echo "Hello" > $out/text.txt
ln -s $out/text.txt $out/symlink
echo "doc none $out/symlink" > $out/nix-support/hydra-build-products
