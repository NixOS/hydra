use strict;
system("initdb -D postgres") == 0 or die;
system("pg_ctl -D postgres -o \"-F -p 6433 -h '' -k /tmp \" -w start") == 0 or die;
system("createdb -p 6433 hydra-test-suite") == 0 or die;
system("hydra-init") == 0 or die;
