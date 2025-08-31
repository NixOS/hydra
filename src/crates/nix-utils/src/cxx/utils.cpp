#include "nix-utils/include/utils.h"

#include <nix/store/store-api.hh>

rust::String extract_opt_path(const nix::Store &store,
                              const std::optional<nix::StorePath> &v) {
  // TODO(conni2461): Replace with option
  return v ? store.printStorePath(*v) : "";
}

rust::Vec<rust::String> extract_path_set(const nix::Store &store,
                                         const nix::StorePathSet &set) {
  rust::Vec<rust::String> data;
  data.reserve(set.size());
  for (const nix::StorePath &path : set) {
    data.emplace_back(store.printStorePath(path));
  }
  return data;
}

rust::Vec<rust::String> extract_paths(const nix::Store &store,
                                      const nix::StorePaths &set) {
  rust::Vec<rust::String> data;
  data.reserve(set.size());
  for (const nix::StorePath &path : set) {
    data.emplace_back(store.printStorePath(path));
  }
  return data;
}
