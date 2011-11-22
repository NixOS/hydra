{pkgs}:

with pkgs;

[ perlPackages.CatalystDevel
  perlPackages.CatalystPluginSessionStoreFastMmap
  perlPackages.CatalystPluginStackTrace
  perlPackages.CatalystPluginAuthorizationRoles
  perlPackages.CatalystPluginSessionStateCookie
  perlPackages.CatalystAuthenticationStoreDBIxClass
  perlPackages.CatalystViewTT
  perlPackages.CatalystViewDownload
  perlPackages.CatalystViewJSON
  perlPackages.CatalystXScriptServerStarman
  perlPackages.XMLSimple
  perlPackages.IPCRun
  perlPackages.IOCompress
  perlPackages.Readonly
  perlPackages.DBDPg
  perlPackages.DBDSQLite
  perlPackages.EmailSender
  perlPackages.TextTable
  perlPackages.TextDiff
  perlPackages.FileSlurp
  perlPackages.NetTwitterLite
  perlPackages.PadWalker
  perlPackages.DataDump
  perlPackages.JSONXS
  perlPackages.DateTime
  perlPackages.DigestSHA1
  perlPackages.CryptRandPasswd
  perlPackages.TestMore
  perlPackages.SysHostnameLong
  perlPackages.Starman
  perlPackages.nixPerl
]
