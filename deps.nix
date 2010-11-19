{pkgs}:

with pkgs;

let

  nixPerl = buildPerlPackage {
    name = "Nix-0.15";
    src = fetchsvn {
      url = https://svn.nixos.org/repos/nix/nix-perl/trunk;
      rev = 24765;
      sha256 = "12ah8c8p9bx55hd17lhcfc74bd4r1677dxy0id3008pww1aklir7";
    };
    NIX_PREFIX = nixSqlite;
    doCheck = false; # tests currently don't work
  };

in

[ perlPackages.CatalystDevel
  perlPackages.CatalystPluginSessionStoreFastMmap
  perlPackages.CatalystPluginStackTrace
  perlPackages.CatalystPluginAuthorizationRoles
  perlPackages.CatalystAuthenticationStoreDBIxClass
  perlPackages.CatalystViewTT
  perlPackages.CatalystEngineHTTPPrefork
  perlPackages.CatalystViewDownload
  perlPackages.XMLSimple
  perlPackages.IPCRun
  perlPackages.IOCompressBzip2
  perlPackages.Readonly
  perlPackages.DBDPg
  perlPackages.EmailSender
  perlPackages.TextTable
  perlPackages.NetTwitterLite
  perlPackages.PadWalker
  perlPackages.DataDump
  perlPackages.JSONXS
  perlPackages.DateTime
  nixPerl
]
