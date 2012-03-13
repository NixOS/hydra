{ pkgs }:

with pkgs;

[ perlPackages.CatalystAuthenticationStoreDBIxClass
  perlPackages.CatalystPluginAccessLog
  perlPackages.CatalystPluginAuthorizationRoles
  perlPackages.CatalystPluginSessionStateCookie
  perlPackages.CatalystPluginSessionStoreFastMmap
  perlPackages.CatalystPluginStackTrace
  perlPackages.CatalystViewDownload
  perlPackages.CatalystViewJSON
  perlPackages.CatalystViewTT
  perlPackages.CatalystXScriptServerStarman
  perlPackages.CryptRandPasswd
  perlPackages.DBDPg
  perlPackages.DBDSQLite
  perlPackages.DataDump
  perlPackages.DateTime
  perlPackages.DigestSHA1
  perlPackages.EmailSender
  perlPackages.FileSlurp
  perlPackages.IOCompress
  perlPackages.IPCRun
  perlPackages.JSONXS
  perlPackages.NetTwitterLite
  perlPackages.PadWalker
  perlPackages.CatalystDevel
  perlPackages.Readonly
  perlPackages.SQLSplitStatement
  perlPackages.Starman
  perlPackages.Switch     # XXX: seems to be an indirect dep of `hydra-build'
  perlPackages.SysHostnameLong
  perlPackages.TestMore
  perlPackages.TextDiff
  perlPackages.TextTable
  perlPackages.XMLSimple
  nixUnstable
]
