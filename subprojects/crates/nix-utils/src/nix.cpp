#include "nix-utils/include/nix.h"
#include "nix-utils/include/utils.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <nix/store/derivations.hh>
#include <nix/store/remote-store.hh>
#include <nix/store/store-api.hh>
#include <nix/store/store-open.hh>

#include "nix/store/export-import.hh"
#include <nix/main/shared.hh>
#include <nix/store/binary-cache-store.hh>
#include <nix/store/globals.hh>
#include <nix/store/s3-binary-cache-store.hh>
#include <nix/util/nar-accessor.hh>

#include <nlohmann/json.hpp>

static std::atomic<bool> initializedNix = false;
static std::mutex nixInitMtx;

namespace nix_utils {
void init_nix() {
  if (!initializedNix) {
    // We need this mutex here. if we have multiple threads that want to do
    // init_nix at the same time.
    // We need to ensure that initNix is finished on all threads before setting
    // initializedNix.
    // We also need to ensure that initNix not runs multiple times at the same
    // time
    std::lock_guard<std::mutex> lock(nixInitMtx);
    if (!initializedNix) {
      nix::initNix();
      initializedNix = true;
    }
  }
}

StoreWrapper::StoreWrapper(nix::ref<nix::Store> _store) : _store(_store) {}

std::unique_ptr<StoreWrapper> init(rust::Str uri) {
  init_nix();
  if (uri.empty()) {
    nix::ref<nix::Store> _store = nix::openStore();
    return std::make_unique<StoreWrapper>(_store);
  } else {
    nix::ref<nix::Store> _store = nix::openStore(AS_STRING(uri));
    return std::make_unique<StoreWrapper>(_store);
  }
}

rust::String get_store_dir_for(const StoreWrapper &wrapper) {
  return wrapper._store->storeDir;
}
rust::String get_build_dir() {
  auto &localSettings = nix::settings.getLocalSettings();
  auto buildDir = localSettings.buildDir.get();
  return buildDir.has_value()
             ? buildDir->string()
             : (nix::settings.nixStateDir / "builds").string();
}
rust::String get_log_dir() { return nix::settings.getLogFileSettings().nixLogDir.string(); }
rust::String get_state_dir() { return nix::settings.nixStateDir.string(); }


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
  for (const auto &sig : info->sigs) {
    sigs.push_back(sig.to_string());
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
    rust::Fn<size_t(rust::Slice<uint8_t>, size_t, size_t, size_t)> callback,
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
  auto paths = nix::importPaths(*store, source,
                                check_sigs ? nix::CheckSigs : nix::NoCheckSigs);
}

void import_paths_with_fd(const StoreWrapper &wrapper, bool check_sigs,
                          int32_t fd) {
  nix::FdSource source(fd);

  auto store = wrapper._store;
  nix::importPaths(*store, source,
                   check_sigs ? nix::CheckSigs : nix::NoCheckSigs);
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
    nix::exportPaths(*store, path_set, sink);
  } catch (StopExport &e) {
    // Intentionally do nothing. We're only using the exception as a
    // short-circuiting mechanism.
  }
}

void nar_from_path(const StoreWrapper &wrapper, rust::Str path,
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
  try {
    store->narFromPath(store->followLinksToStorePath(AS_VIEW(path)), sink);
  } catch (StopExport &e) {
    // Intentionally do nothing. We're only using the exception as a
    // short-circuiting mechanism.
  }
}

rust::String list_nar_deep(const StoreWrapper &wrapper, rust::Str path) {
  auto store = wrapper._store;
  auto [store_path, rest] = store->toStorePath(AS_VIEW(path));

  nlohmann::json j = {
      {"version", 1},
      {"root", nix::listNarDeep(*store->getFSAccessor(),
                                nix::CanonPath{store_path.to_string()} /
                                    nix::CanonPath{rest})},
  };

  return j.dump();
}

void ensure_path(const StoreWrapper &wrapper, rust::Str path) {
  auto store = wrapper._store;
  store->ensurePath(store->followLinksToStorePath(AS_VIEW(path)));
}

rust::String try_resolve_drv(const StoreWrapper &wrapper, rust::Str path) {
  auto store = wrapper._store;

  auto drv = store->readDerivation(store->parseStorePath(AS_VIEW(path)));
  auto resolved = drv.tryResolve(*store);
  if (!resolved) {
    return "";
  }

  auto resolved_path = store->writeDerivation(*resolved, nix::NoRepair);
  // TODO: return drv not drv path
  return extract_opt_path(*store, resolved_path);
}

rust::Vec<DerivationHash> static_output_hashes(const StoreWrapper &wrapper,
                                               rust::Str drv_path) {
  auto store = wrapper._store;

  auto drvHashes = staticOutputHashes(
      *store, store->readDerivation(store->parseStorePath(AS_VIEW(drv_path))));
  rust::Vec<DerivationHash> data;
  data.reserve(drvHashes.size());
  for (auto &[name, hash] : drvHashes) {
    data.emplace_back(
        DerivationHash{name, hash.to_string(nix::HashFormat::Base16, true)});
  }
  return data;
}
} // namespace nix_utils
