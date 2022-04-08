bin_PROGRAMS = hydra-queue-runner

hydra_queue_runner_SOURCES = hydra-queue-runner.cc queue-monitor.cc dispatcher.cc \
 builder.cc build-result.cc build-remote.cc metrics.cc \
 hydra-build-result.hh counter.hh state.hh db.hh \
 nar-extractor.cc nar-extractor.hh metrics.hh
hydra_queue_runner_LDADD = $(NIX_LIBS) -lpqxx -lprometheus-cpp-pull -lprometheus-cpp-core
hydra_queue_runner_CXXFLAGS = $(NIX_CFLAGS) -Wall -I ../libhydra -Wno-deprecated-declarations
