use strict;
system("chmod -R a+w nix") == 0 or die;
system("rm -rf data nix git-repo hg-repo svn-repo svn-checkout svn-checkout-repo bzr-repo bzr-checkout-repo darcs-repo") == 0 or die;
system("rm -f .*-state") == 0 or die;
system("dropdb hydra-test-suite") == 0 or die;
