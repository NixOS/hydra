#pragma once

#include "rust/cxx.h"
#include <memory>
#include <nix/main/shared.hh>

namespace nix_utils {
class StoreWrapper {
public:
  StoreWrapper(nix::ref<nix::Store> _store);

  nix::ref<nix::Store> _store;
};
} // namespace nix_utils

// we need to include this after StoreWrapper
#include "nix-utils/src/lib.rs.h"

namespace nix_utils {
std::shared_ptr<StoreWrapper> init(rust::Str uri);

rust::String get_nix_prefix();
rust::String get_store_dir();
rust::String get_log_dir();
rust::String get_state_dir();
rust::String get_this_system();
rust::Vec<rust::String> get_extra_platforms();
rust::Vec<rust::String> get_system_features();
bool get_use_cgroups();
void set_verbosity(int32_t level);

bool is_valid_path(const StoreWrapper &wrapper, rust::Str path);
InternalPathInfo query_path_info(const StoreWrapper &wrapper, rust::Str path);
void clear_path_info_cache(const StoreWrapper &wrapper);
uint64_t compute_closure_size(const StoreWrapper &wrapper, rust::Str path);
rust::Vec<rust::String> compute_fs_closure(const StoreWrapper &wrapper,
                                           rust::Str path, bool flip_direction,
                                           bool include_outputs,
                                           bool include_derivers);
rust::Vec<rust::String>
compute_fs_closures(const StoreWrapper &wrapper,
                    rust::Slice<const rust::Str> paths, bool flip_direction,
                    bool include_outputs, bool include_derivers, bool toposort);
void upsert_file(const StoreWrapper &wrapper, rust::Str path, rust::Str data,
                 rust::Str mime_type);
StoreStats get_store_stats(const StoreWrapper &wrapper);
S3Stats get_s3_stats(const StoreWrapper &wrapper);
void copy_paths(const StoreWrapper &src_store, const StoreWrapper &dst_store,
                rust::Slice<const rust::Str> paths, bool repair,
                bool check_sigs, bool substitute);

void import_paths(
    const StoreWrapper &wrapper, bool check_sigs, size_t runtime, size_t reader,
    rust::Fn<size_t(rust::Slice<uint8_t>, size_t, size_t, size_t)> callback,
    size_t user_data);
void import_paths_with_fd(const StoreWrapper &wrapper, bool check_sigs,
                          int32_t fd);
void export_paths(const StoreWrapper &src_store,
                  rust::Slice<const rust::Str> paths,
                  rust::Fn<bool(rust::Slice<const uint8_t>, size_t)> callback,
                  size_t userdata);

rust::String try_resolve_drv(const StoreWrapper &wrapper, rust::Str path);
} // namespace nix_utils
