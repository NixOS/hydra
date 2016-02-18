#pragma once

#include "binary-cache-store.hh"

namespace nix {

class LocalBinaryCacheStore : public BinaryCacheStore
{
private:

    Path binaryCacheDir;

public:

    LocalBinaryCacheStore(ref<Store> localStore, const Path & binaryCacheDir,
        const Path & secretKeyFile, const Path & publicKeyFile);

    void init() override;

protected:

    bool fileExists(const std::string & path) override;

    void upsertFile(const std::string & path, const std::string & data) override;

    std::string getFile(const std::string & path) override;

};

}
