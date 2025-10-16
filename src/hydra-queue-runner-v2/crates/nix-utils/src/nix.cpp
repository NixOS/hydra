#include "nix-utils/include/nix.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <nix/store/derivations.hh>
#include <nix/store/remote-store.hh>
#include <nix/store/store-api.hh>
#include <nix/store/store-open.hh>

#include <nix/main/shared.hh>
#include <nix/store/binary-cache-store.hh>
#include <nix/store/globals.hh>
#include <nix/store/s3-binary-cache-store.hh>

static std::atomic<bool> initializedNix = false;

#define AS_VIEW(rstr) std::string_view(rstr.data(), rstr.length())
#define AS_STRING(rstr) std::string(rstr.data(), rstr.length())

static inline rust::String
extract_opt_path(const nix::Store &store,
                 const std::optional<nix::StorePath> &v) {
  // TODO(conni2461): Replace with option
  return v ? store.printStorePath(*v) : "";
}

static inline rust::Vec<rust::String>
extract_path_set(const nix::Store &store, const nix::StorePathSet &set) {
  rust::Vec<rust::String> data;
  data.reserve(set.size());
  for (const nix::StorePath &path : set) {
    data.emplace_back(store.printStorePath(path));
  }
  return data;
}

static inline rust::Vec<rust::String>
extract_paths(const nix::Store &store, const nix::StorePaths &set) {
  rust::Vec<rust::String> data;
  data.reserve(set.size());
  for (const nix::StorePath &path : set) {
    data.emplace_back(store.printStorePath(path));
  }
  return data;
}

namespace nix_utils {
StoreWrapper::StoreWrapper(nix::ref<nix::Store> _store) : _store(_store) {}

std::shared_ptr<StoreWrapper> init(rust::Str uri) {
  if (!initializedNix) {
    initializedNix = true;
    nix::initNix();
  }
  if (uri.empty()) {
    nix::ref<nix::Store> _store = nix::openStore();
    return std::make_shared<StoreWrapper>(_store);
  } else {
    nix::ref<nix::Store> _store = nix::openStore(AS_STRING(uri));
    return std::make_shared<StoreWrapper>(_store);
  }
}

rust::String get_nix_prefix() { return nix::settings.nixPrefix; }
rust::String get_store_dir() { return nix::settings.nixStore; }
rust::String get_log_dir() { return nix::settings.nixLogDir; }
rust::String get_state_dir() { return nix::settings.nixStateDir; }
rust::String get_this_system() { return nix::settings.thisSystem.get(); }
rust::Vec<rust::String> get_extra_platforms() {
  auto set = nix::settings.extraPlatforms.get();
  rust::Vec<rust::String> data;
  data.reserve(set.size());
  for (const auto &val : set) {
    data.emplace_back(val);
  }
  return data;
}
rust::Vec<rust::String> get_system_features() {
  auto set = nix::settings.systemFeatures.get();
  rust::Vec<rust::String> data;
  data.reserve(set.size());
  for (const auto &val : set) {
    data.emplace_back(val);
  }
  return data;
}
bool get_use_cgroups() {
#ifdef __linux__
  return nix::settings.useCgroups;
#endif
  return false;
}
void set_verbosity(int32_t level) { nix::verbosity = (nix::Verbosity)level; }

bool is_valid_path(const StoreWrapper &wrapper, rust::Str path) {
  auto store = wrapper._store;
  return store->isValidPath(store->parseStorePath(AS_VIEW(path)));
}

InternalPathInfo query_path_info(const StoreWrapper &wrapper, rust::Str path) {
  auto store = wrapper._store;
  auto info = store->queryPathInfo(store->parseStorePath(AS_VIEW(path)));

  std::string narhash = info->narHash.to_string(nix::HashFormat::Nix32, true);

  rust::Vec<rust::String> refs = extract_path_set(*store, info->references);

  rust::Vec<rust::String> sigs;
  sigs.reserve(info->sigs.size());
  for (const std::string &sig : info->sigs) {
    sigs.push_back(sig);
  }

  // TODO(conni2461): Replace "" with option
  return InternalPathInfo{
      extract_opt_path(*store, info->deriver),
      narhash,
      info->registrationTime,
      info->narSize,
      refs,
      sigs,
      info->ca ? nix::renderContentAddress(*info->ca) : "",
  };
}

uint64_t compute_closure_size(const StoreWrapper &wrapper, rust::Str path) {
  auto store = wrapper._store;
  nix::StorePathSet closure;
  store->computeFSClosure(store->parseStorePath(AS_VIEW(path)), closure, false,
                          false);

  uint64_t totalNarSize = 0;
  for (auto &p : closure) {
    totalNarSize += store->queryPathInfo(p)->narSize;
  }
  return totalNarSize;
}

void clear_path_info_cache(const StoreWrapper &wrapper) {
  auto store = wrapper._store;
  store->clearPathInfoCache();
}

rust::Vec<rust::String> compute_fs_closure(const StoreWrapper &wrapper,
                                           rust::Str path, bool flip_direction,
                                           bool include_outputs,
                                           bool include_derivers) {
  auto store = wrapper._store;
  nix::StorePathSet path_set;
  store->computeFSClosure(store->parseStorePath(AS_VIEW(path)), path_set,
                          flip_direction, include_outputs, include_derivers);
  return extract_path_set(*store, path_set);
}

rust::Vec<rust::String> compute_fs_closures(const StoreWrapper &wrapper,
                                            rust::Slice<const rust::Str> paths,
                                            bool flip_direction,
                                            bool include_outputs,
                                            bool include_derivers,
                                            bool toposort) {
  auto store = wrapper._store;
  nix::StorePathSet path_set;
  for (auto &path : paths) {
    store->computeFSClosure(store->parseStorePath(AS_VIEW(path)), path_set,
                            flip_direction, include_outputs, include_derivers);
  }
  if (toposort) {
    auto sorted = store->topoSortPaths(path_set);
    return extract_paths(*store, sorted);
  } else {
    return extract_path_set(*store, path_set);
  }
}

void upsert_file(const StoreWrapper &wrapper, rust::Str path, rust::Str data,
                 rust::Str mime_type) {
  auto store = wrapper._store.dynamic_pointer_cast<nix::BinaryCacheStore>();
  if (!store) {
    throw nix::Error("Not a binary chache store");
  }
  store->upsertFile(AS_STRING(path), AS_STRING(data), AS_STRING(mime_type));
}

StoreStats get_store_stats(const StoreWrapper &wrapper) {
  auto store = wrapper._store;
  auto &stats = store->getStats();
  return StoreStats{
      stats.narInfoRead.load(),
      stats.narInfoReadAverted.load(),
      stats.narInfoMissing.load(),
      stats.narInfoWrite.load(),
      stats.pathInfoCacheSize.load(),
      stats.narRead.load(),
      stats.narReadBytes.load(),
      stats.narReadCompressedBytes.load(),
      stats.narWrite.load(),
      stats.narWriteAverted.load(),
      stats.narWriteBytes.load(),
      stats.narWriteCompressedBytes.load(),
      stats.narWriteCompressionTimeMs.load(),
  };
}

S3Stats get_s3_stats(const StoreWrapper &wrapper) {
  auto store = wrapper._store;
  auto s3Store = dynamic_cast<nix::S3BinaryCacheStore *>(&*store);
  if (!s3Store) {
    throw nix::Error("Not a s3 binary chache store");
  }
  auto &stats = s3Store->getS3Stats();
  return S3Stats{
      stats.put.load(),  stats.putBytes.load(), stats.putTimeMs.load(),
      stats.get.load(),  stats.getBytes.load(), stats.getTimeMs.load(),
      stats.head.load(),
  };
}

void copy_paths(const StoreWrapper &src_store, const StoreWrapper &dst_store,
                rust::Slice<const rust::Str> paths, bool repair,
                bool check_sigs, bool substitute) {
  nix::StorePathSet path_set;
  for (auto &path : paths) {
    path_set.insert(src_store._store->parseStorePath(AS_VIEW(path)));
  }
  nix::copyPaths(*src_store._store, *dst_store._store, path_set,
                 repair ? nix::Repair : nix::NoRepair,
                 check_sigs ? nix::CheckSigs : nix::NoCheckSigs,
                 substitute ? nix::Substitute : nix::NoSubstitute);
}

void import_paths(
    const StoreWrapper &wrapper, bool check_sigs, size_t runtime, size_t reader,
    rust::Fn<size_t(rust::Slice<uint8_t>, size_t, size_t, size_t)>
        callback,
    size_t user_data) {
  nix::LambdaSource source([=](char *out, size_t out_len) {
    auto data = rust::Slice<uint8_t>((uint8_t *)out, out_len);
    size_t ret = (*callback)(data, runtime, reader, user_data);
    if (!ret) {
      throw nix::EndOfFile("End of stream reached");
    }
    return ret;
  });

  auto store = wrapper._store;
  auto paths = store->importPaths(source, check_sigs ? nix::CheckSigs
                                                     : nix::NoCheckSigs);
}

void import_paths_with_fd(const StoreWrapper &wrapper, bool check_sigs,
                          int32_t fd) {
  nix::FdSource source(fd);

  auto store = wrapper._store;
  store->importPaths(source, check_sigs ? nix::CheckSigs : nix::NoCheckSigs);
}

class StopExport : public std::exception {
public:
  const char *what() { return "Stop exporting nar"; }
};

void export_paths(const StoreWrapper &wrapper,
                  rust::Slice<const rust::Str> paths,
                  rust::Fn<bool(rust::Slice<const uint8_t>, size_t)> callback,
                  size_t user_data) {
  nix::LambdaSink sink([=](std::string_view v) {
    auto data = rust::Slice<const uint8_t>((const uint8_t *)v.data(), v.size());
    bool ret = (*callback)(data, user_data);
    if (!ret) {
      throw StopExport();
    }
  });

  auto store = wrapper._store;
  nix::StorePathSet path_set;
  for (auto &path : paths) {
    path_set.insert(store->followLinksToStorePath(AS_VIEW(path)));
  }
  try {
    store->exportPaths(path_set, sink);
  } catch (StopExport &e) {
    // Intentionally do nothing. We're only using the exception as a
    // short-circuiting mechanism.
  }
}

rust::String try_resolve_drv(const StoreWrapper &wrapper, rust::Str path) {
  auto store = wrapper._store;

  auto drv = store->readDerivation(store->parseStorePath(AS_VIEW(path)));
  auto resolved = drv.tryResolve(*store);
  if (!resolved) {
    return "";
  }

  auto resolved_path = writeDerivation(*store, *resolved, nix::NoRepair, false);
  // TODO: return drv not drv path
  return extract_opt_path(*store, resolved_path);
}
} // namespace nix_utils
