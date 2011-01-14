bin_PROGRAMS = hydra_eval_jobs

hydra_eval_jobs_SOURCES = hydra_eval_jobs.cc
hydra_eval_jobs_LDADD = -lmain -lexpr -L$(nix)/lib/nix $(BDW_GC_LIBS)

AM_CXXFLAGS =					\
 -I$(nix)/include/nix				\
  $(BDW_GC_CFLAGS)
