#pragma once

#include "rust/cxx.h"
#include <nix/main/shared.hh>

#define AS_VIEW(rstr) std::string_view(rstr.data(), rstr.length())
#define AS_STRING(rstr) std::string(rstr.data(), rstr.length())

rust::String extract_opt_path(const nix::Store &store,
                              const std::optional<nix::StorePath> &v);
rust::Vec<rust::String> extract_path_set(const nix::Store &store,
                                         const nix::StorePathSet &set);
rust::Vec<rust::String> extract_paths(const nix::Store &store,
                                      const nix::StorePaths &set);
