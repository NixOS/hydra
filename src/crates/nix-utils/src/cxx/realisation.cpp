#include "nix-utils/include/realisation.h"
#include "nix-utils/include/utils.h"

#include "nix/store/nar-info-disk-cache.hh"
#include "nix/store/store-api.hh"
#include "nix/util/json-utils.hh"

namespace nix_utils {
InternalRealisation::InternalRealisation(
    nix::ref<nix::Realisation> _realisation)
    : _realisation(_realisation) {}

rust::String InternalRealisation::as_json() const {
  return nlohmann::json(*_realisation).dump();
}

SharedRealisation
InternalRealisation::to_rust(const nix_utils::StoreWrapper &wrapper) const {
  auto store = wrapper._store;

  rust::Vec<rust::String> signatures;
  signatures.reserve(_realisation->signatures.size());
  for (const std::string &sig : _realisation->signatures) {
    signatures.push_back(sig);
  }

  rust::Vec<DrvOutputPathTuple> dependent;
  dependent.reserve(_realisation->dependentRealisations.size());
  for (auto const &[drv_output, store_path] :
       _realisation->dependentRealisations) {
    dependent.push_back(DrvOutputPathTuple{
        DrvOutput{
            drv_output.strHash(),
            drv_output.outputName,
        },
        store->printStorePath(store_path),
    });
  }

  return SharedRealisation{
      DrvOutput{
          _realisation->id.strHash(),
          _realisation->id.outputName,
      },
      store->printStorePath(_realisation->outPath),
      signatures,
      dependent,
  };
}

DrvOutput InternalRealisation::get_drv_output() const {
  return DrvOutput{_realisation->id.strHash(), _realisation->id.outputName};
}

rust::String InternalRealisation::fingerprint() const {
  return _realisation->fingerprint();
}

void InternalRealisation::sign(rust::Str secret_key) {
  nix::SecretKey s(AS_VIEW(secret_key));
  nix::LocalSigner signer(std::move(s));
  _realisation->sign(signer);
}

void InternalRealisation::clear_signatures() {
  _realisation->signatures.clear();
}

void InternalRealisation::write_to_disk_cache(
    const nix_utils::StoreWrapper &wrapper) const {
  auto disk_cache = nix::getNarInfoDiskCache();

  if (disk_cache.get_ptr()) {
    auto store = wrapper._store;
    disk_cache->upsertRealisation(store->config.getHumanReadableURI(),
                                  *_realisation.get_ptr());
  }
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

std::shared_ptr<InternalRealisation> parse_realisation(rust::Str json_string) {
  nlohmann::json encoded = nlohmann::json::parse(json_string);
  nix::Realisation realisation =
      nlohmann::adl_serializer<nix::Realisation>::from_json(encoded);
  return std::make_unique<InternalRealisation>(
      nix::make_ref<nix::Realisation>(realisation));
}
} // namespace nix_utils
