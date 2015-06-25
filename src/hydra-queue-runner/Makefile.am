bin_PROGRAMS = hydra-queue-runner

hydra_queue_runner_SOURCES = hydra-queue-runner.cc build-result.cc build-remote.cc \
 build-remote.hh build-result.hh counter.hh pool.hh sync.hh token-server.hh
hydra_queue_runner_LDADD = $(NIX_LIBS) -lpqxx

AM_CXXFLAGS = $(NIX_CFLAGS) -Wall
