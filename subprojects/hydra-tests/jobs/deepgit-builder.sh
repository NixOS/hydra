#! /bin/sh

set -e
mkdir $out
cp -v $src/* $out/
git describe --long > $out/Version
