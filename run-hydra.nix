{ foreman, mkShell, hydra, netcat, postgresql95 }:
{ doCheck ? true }:
mkShell {
  buildInputs = [
    foreman (hydra.overrideAttrs (_: { inherit doCheck; })) netcat postgresql95
  ];

  shellHook = ''
    export HYDRA_HOME="src/"
    mkdir -p .hydra-data
    export HYDRA_DATA="$(pwd)/.hydra-data"
    export HYDRA_DBI='dbi:Pg:dbname=hydra;host=localhost;port=64444'

    exec foreman start
  '';
}
