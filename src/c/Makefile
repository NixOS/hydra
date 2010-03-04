NIX = /home/eelco/Dev/nix/inst
ATERM = /home/eelco/Dev/nix/externals/inst-aterm

hydra_eval_jobs: hydra_eval_jobs.cc
	libtool --mode=link g++ -o hydra_eval_jobs hydra_eval_jobs.cc -I$(NIX)/include/nix -I$(ATERM)/include -L$(NIX)/lib/nix/ -lmain -lexpr -Wall
