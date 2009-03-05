NIX = /home/eelco/Dev/nix/inst
ATERM = /home/eelco/Dev/nix/externals/inst-aterm

eval-jobs: eval-jobs.cc
	libtool --mode=link g++ -o eval-jobs eval-jobs.cc -I$(NIX)/include/nix -I$(ATERM)/include -L$(NIX)/lib/nix/ -lmain -lexpr -L$(ATERM)/lib -lATerm
