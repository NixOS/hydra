{pkgs}:

with pkgs;

let

  nixPerl = buildPerlPackage {
    name = "Nix-0.15";
    src = fetchsvn {
      url = https://svn.nixos.org/repos/nix/nix-perl/trunk;
      rev = 20373;
      sha256 = "153wj8kcdf9hzg89bjm8s8d6byrhcw0dazzrwc04a7g79j5xjfaj";
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
  nixPerl
]
