# Temporary packaging of foreman from a fork that adds Socketfile support.
# Once https://github.com/ddollar/foreman/pull/816 is merged and released,
# switch back to the nixpkgs foreman package.
{
  stdenv,
  ruby,
  makeWrapper,
  foreman-src,
}:

let
  thor = ruby.gems.thor;
in
stdenv.mkDerivation {
  pname = "foreman";
  version = "0.90.0-socketfile";

  src = foreman-src;

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [
    ruby
    thor
  ];

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/bin $out/lib
    cp -r lib/* $out/lib/
    cp -r data $out/data
    cp bin/foreman $out/bin/foreman
    wrapProgram $out/bin/foreman \
      --prefix RUBYLIB : "$out/lib:${thor}/lib/ruby/gems/${ruby.version.libDir}/gems/thor-*/lib" \
      --set GEM_PATH "${thor}/lib/ruby/gems/${ruby.version.libDir}"
  '';
}
