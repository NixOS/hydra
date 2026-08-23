#! /bin/sh

# Stands in for a generator that has to run before anyone can know what
# the jobs are: a manifest parser, a matrix expander, a codegen step.
mkdir $out
echo '[ "alpha" "beta" "gamma" "delta" ]' > $out/names.nix
