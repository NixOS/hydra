use strict;
system("createdb hydra-test-suite") == 0 or die;
system("hydra-init") == 0 or die;
