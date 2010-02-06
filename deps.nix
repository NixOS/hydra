{pkgs}:

with pkgs;

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
]

