#
# jobset example file. This file canbe referenced as Nix expression
# in a jobset configuration along with inputs for nixpkgs and the
# repository containing this file.
#
{ ... }:
let
  # <nixpkgs> is set to the value designated by the nixpkgs input of the
  # jobset configuration.
  pkgs = (import <nixpkgs> {});
in {
  hello = pkgs.hello;
}
