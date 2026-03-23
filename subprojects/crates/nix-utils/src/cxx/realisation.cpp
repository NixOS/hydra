#include "nix-utils/include/realisation.h"
#include "nix-utils/include/utils.h"

#include "nix/store/store-api.hh"

#include <nlohmann/json.hpp>

namespace nix_utils {
InternalRealisation::InternalRealisation(
    nix::ref<nix::Realisation> _realisation)
    : _realisation(_realisation) {}

rust::String InternalRealisation::as_json() const {
  return nlohmann::json(*_realisation).dump();
}

std::shared_ptr<InternalRealisation>
query_raw_realisation(const nix_utils::StoreWrapper &wrapper,
                      rust::Str output_id) {
  auto store = wrapper._store;
  auto realisation =
      store->queryRealisation(nix::DrvOutput::parse(AS_STRING(output_id)));
  if (!realisation) {
    throw nix::Error("output_id '%s' isn't found", output_id);
  }

  return std::make_unique<InternalRealisation>(
      nix::make_ref<nix::Realisation>((nix::Realisation &)*realisation));
}

} // namespace nix_utils
