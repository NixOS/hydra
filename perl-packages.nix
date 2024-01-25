prev:
with prev.perlPackages;
let inherit (prev) lib fetchurl;
in rec {
  ClassErrorHandler = buildPerlPackage {
    pname = "Class-ErrorHandler";
    version = "0.04";
    src = fetchurl {
      url = "mirror://cpan/authors/id/T/TO/TOKUHIROM/Class-ErrorHandler-0.04.tar.gz";
      sha256 = "342d2dcfc797a20bee8179b1b96b85c0ae7a5b48827359523cd8c74c3e704502";
    };
    meta = {
      homepage = "https://github.com/tokuhirom/Class-ErrorHandler";
      description = "Base class for error handling";
      license = with lib.licenses; [ artistic1 gpl1Plus ];
    };
  };
  OIDCLite = buildPerlModule {
    pname = "OIDC-Lite";
    version = "0.10";
    src = fetchurl {
      url = "mirror://cpan/authors/id/R/RI/RITOU/OIDC-Lite-0.10.tar.gz";
      sha256 = "529096272a160d8cd947bec79e01b48639db93726432b4d93039a7507421245a";
    };
    buildInputs = [ CryptOpenSSLRSA TestMockLWPConditional TestMockObject ];
    propagatedBuildInputs = [ ClassAccessor DataDump JSONWebToken JSONXS OAuthLite2 ParamsValidate ];
    meta = {
      homepage = "https://github.com/ritou/p5-oidc-lite";
      description = "OpenID Connect Library";
      license = with lib.licenses; [ artistic1 gpl1Plus ];
    };
  };
  OAuthLite = buildPerlPackage {
    pname = "OAuth-Lite";
    version = "1.35";
    src = fetchurl {
      url = "mirror://cpan/authors/id/L/LY/LYOKATO/OAuth-Lite-1.35.tar.gz";
      sha256 = "740528f8345bcb8849c1e3bfc91510b3c7f9df6255af09987d4175c1dea43c5e";
    };
    propagatedBuildInputs = [ ClassAccessor ClassDataAccessor ClassErrorHandler CryptOpenSSLRSA CryptOpenSSLRandom LWP ListMoreUtils UNIVERSALrequire URI ];
    meta = {
      description = "OAuth framework";
      license = with lib.licenses; [ artistic1 gpl1Plus ];
    };
  };
  TestMockLWPConditional = buildPerlModule {
    pname = "Test-Mock-LWP-Conditional";
    version = "0.04";
    src = fetchurl {
      url = "mirror://cpan/authors/id/M/MA/MASAKI/Test-Mock-LWP-Conditional-0.04.tar.gz";
      sha256 = "8817129488f1eae4896aae59b8e09e94f720fdd697a73aef13241e8123940667";
    };
    buildInputs = [ ModuleBuildTiny TestFakeHTTPD TestUseAllModules TestTCP TestSharedFork ];
    propagatedBuildInputs = [ ClassMethodModifiers LWP MathRandomSecure SubInstall ];
    meta = {
      homepage = "https://github.com/masaki/Test-Mock-LWP-Conditional";
      description = "Stubbing on LWP request";
      license = with lib.licenses; [ artistic1 gpl1Plus ];
    };
  };
  OAuthLite2 = buildPerlModule {
    pname = "OAuth-Lite2";
    version = "0.11";
    src = fetchurl {
      url = "mirror://cpan/authors/id/R/RI/RITOU/OAuth-Lite2-0.11.tar.gz";
      sha256 = "01417ec28acefd25a839bdb4b846056036ae122c181dab907e48e0bdb938686a";
    };
    buildInputs = [ ModuleBuildTiny ];
    propagatedBuildInputs = [ ClassAccessor ClassErrorHandler DataDump HashMultiValue IOString JSONXS LWP ParamsValidate Plack StringRandom TryTiny URI XMLLibXML ];
    meta = {
      homepage = "https://github.com/ritou/p5-oauth-lite2";
      description = "OAuth 2.0 Library";
      license = with lib.licenses; [ artistic1 gpl1Plus ];
    };
  };

}
