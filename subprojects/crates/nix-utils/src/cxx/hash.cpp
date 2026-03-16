#include "nix-utils/include/hash.h"
#include "nix-utils/include/utils.h"

#include <nix/util/hash.hh>

namespace nix_utils::hash {
static inline std::optional<nix::HashAlgorithm>
convert_algo(OptionalHashAlgorithm algo) {
  switch (algo) {
  case OptionalHashAlgorithm::MD5:
    return nix::HashAlgorithm::MD5;
  case OptionalHashAlgorithm::SHA1:
    return nix::HashAlgorithm::SHA1;
  case OptionalHashAlgorithm::SHA256:
    return nix::HashAlgorithm::SHA256;
  case OptionalHashAlgorithm::SHA512:
    return nix::HashAlgorithm::SHA512;
  case OptionalHashAlgorithm::BLAKE3:
    return nix::HashAlgorithm::BLAKE3;
  case OptionalHashAlgorithm::None:
  default:
    return std::nullopt;
  };
}

static inline nix::HashFormat convert_format(HashFormat format) {
  switch (format) {
  case HashFormat::Base64:
    return nix::HashFormat::Base64;
  case HashFormat::Nix32:
    return nix::HashFormat::Nix32;
  case HashFormat::Base16:
    return nix::HashFormat::Base16;
  case HashFormat::SRI:
  default:
    return nix::HashFormat::SRI;
  };
}

rust::String convert_hash(rust::Str s, OptionalHashAlgorithm algo,
                          HashFormat out_format) {
  auto h = nix::Hash::parseAny(AS_VIEW(s), convert_algo(algo));
  auto f = convert_format(out_format);
  return h.to_string(f, f == nix::HashFormat::SRI);
}
} // namespace nix_utils::hash
