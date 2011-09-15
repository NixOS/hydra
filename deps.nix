{pkgs}:

with pkgs;

[ perlPackages.CatalystDevel
  perlPackages.CatalystPluginSessionStoreFastMmap
  perlPackages.CatalystPluginStackTrace
  perlPackages.CatalystPluginAuthorizationRoles
  perlPackages.CatalystPluginSessionStateCookie
  perlPackages.CatalystAuthenticationStoreDBIxClass
  perlPackages.CatalystViewTT
  perlPackages.CatalystEngineHTTPPrefork
  perlPackages.CatalystViewDownload
  perlPackages.CatalystViewJSON
  perlPackages.XMLSimple
  perlPackages.IPCRun
  perlPackages.IOCompressBzip2
  perlPackages.Readonly
  perlPackages.DBDPg
  perlPackages.DBDSQLite
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
  perlPackages.SysHostnameLong
  perlPackages.nixPerl
]
