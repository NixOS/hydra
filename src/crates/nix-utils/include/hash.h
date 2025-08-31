#pragma once

#include "rust/cxx.h"

#include "nix-utils/src/hash.rs.h"

namespace nix_utils::hash {
rust::String convert_hash(rust::Str s, OptionalHashAlgorithm algo,
                          HashFormat out_format);
} // namespace nix_utils::hash
