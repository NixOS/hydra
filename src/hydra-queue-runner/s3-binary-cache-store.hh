#pragma once

#include "binary-cache-store.hh"

namespace Aws { namespace Client { class ClientConfiguration; } }
namespace Aws { namespace S3 { class S3Client; } }

namespace nix {

class S3BinaryCacheStore : public BinaryCacheStore
{
private:

    std::string bucketName;

    ref<Aws::Client::ClientConfiguration> config;
    ref<Aws::S3::S3Client> client;

public:

    S3BinaryCacheStore(const StoreFactory & storeFactory,
        const Path & secretKeyFile, const Path & publicKeyFile,
        const std::string & bucketName);

    void init() override;

private:

    ref<Aws::Client::ClientConfiguration> makeConfig();

protected:

    bool fileExists(const std::string & path) override;

    void upsertFile(const std::string & path, const std::string & data) override;

    std::string getFile(const std::string & path) override;

};

}
