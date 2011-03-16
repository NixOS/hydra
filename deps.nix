{pkgs}:

with pkgs;

let

  nixPerl = buildPerlPackage {
    name = "Nix-0.15";
    src = fetchsvn {
      url = https://svn.nixos.org/repos/nix/nix-perl/trunk;
      rev = 24774;
      sha256 = "1akj695gpnbrjlnwd1gdnnnk7ppvpp1qsinjn04az7q6hjqzbm6p";
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
  perlPackages.DigestSHA1
  perlPackages.CryptRandPasswd
  perlPackages.TestMore
  nixPerl
]
