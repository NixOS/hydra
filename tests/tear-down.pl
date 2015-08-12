use strict;

my $fail = 0;

system("dropdb -p 6433 hydra-test-suite") == 0 or $fail = 1;
system("pg_ctl -D postgres -w stop") == 0 or $fail = 1;

system("chmod -R a+w nix") == 0 or $fail = 1;
system("rm -rf postgres data nix git-repo hg-repo svn-repo svn-checkout svn-checkout-repo bzr-repo bzr-checkout-repo darcs-repo") == 0 or $fail = 1;
system("rm -f .*-state") == 0 or $fail = 1;

exit $fail;
