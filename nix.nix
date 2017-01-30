pkgs : with pkgs; rec {
  aws-sdk-cpp' =
    lib.overrideDerivation (aws-sdk-cpp.override {
      apis = ["s3"];
      customMemoryManagement = false;
    }) (attrs: {
      src = fetchFromGitHub {
        owner = "edolstra";
        repo = "aws-sdk-cpp";
        rev = "d1e2479f79c24e2a1df8a3f3ef3278a1c6383b1e";
        sha256 = "1vhgsxkhpai9a7dk38q4r239l6dsz2jvl8hii24c194lsga3g84h";
      };
    });
  nix = lib.overrideDerivation nixUnstable (attrs: {
    src = fetchFromGitHub {
      owner = "NixOS";
      repo = "nix";
      rev = "4be4f6de56f4de77f6a376f1a40ed75eb641bb89";
      sha256 = "0icvbwpca1jh8qkdlayxspdxl5fb0qjjd1kn74x6gs6iy66kndq6";
    };
    buildInputs = attrs.buildInputs ++ [ autoreconfHook bison flex ];
    nativeBuildInputs = attrs.nativeBuildInputs ++ [ aws-sdk-cpp' autoconf-archive ];
    configureFlags = attrs.configureFlags + " --disable-doc-gen";
    preConfigure = "./bootstrap.sh; mkdir -p $doc $man";
  });
}
