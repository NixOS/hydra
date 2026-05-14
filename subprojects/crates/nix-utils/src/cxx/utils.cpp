#include "nix-utils/include/utils.h"

#include <nix/store/store-api.hh>

rust::String extract_opt_path(const std::optional<nix::StorePath> &v) {
  // TODO(conni2461): Replace with option
  if (!v) return "";
  auto s = v->to_string();
  return rust::String(s.data(), s.size());
}

rust::Vec<rust::String> extract_path_set(const nix::StorePathSet &set) {
  rust::Vec<rust::String> data;
  data.reserve(set.size());
  for (const nix::StorePath &path : set) {
    auto s = path.to_string();
    data.push_back(rust::String(s.data(), s.size()));
  }
  return data;
}

rust::Vec<rust::String> extract_paths(const nix::StorePaths &set) {
  rust::Vec<rust::String> data;
  data.reserve(set.size());
  for (const nix::StorePath &path : set) {
    auto s = path.to_string();
    data.push_back(rust::String(s.data(), s.size()));
  }
  return data;
}
