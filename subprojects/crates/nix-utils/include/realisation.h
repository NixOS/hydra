#pragma once

#include "rust/cxx.h"
#include <memory>

#include "nix-utils/include/nix.h"
#include "nix/store/realisation.hh"

namespace nix_utils {
class InternalRealisation {
public:
  InternalRealisation(nix::ref<nix::Realisation> _realisation);

  rust::String as_json() const;

private:
  nix::ref<nix::Realisation> _realisation;
};
} // namespace nix_utils

#include "nix-utils/src/realisation.rs.h"

namespace nix_utils {
std::shared_ptr<InternalRealisation>
query_raw_realisation(const nix_utils::StoreWrapper &wrapper,
                      rust::Str output_id);
} // namespace nix_utils
