rec {
  path = "/nix/store/l9mg93sgx50y88p5rr6x1vib6j1rjsds-coreutils-9.1/bin";

  mkDerivation = args:
    derivation ({
      system = builtins.currentSystem;
      PATH = path;
    } // args);
  mkContentAddressedDerivation = args: mkDerivation ({
    __contentAddressed = true;
    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
  } // args);
}
