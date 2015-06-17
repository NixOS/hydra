#pragma once

#include <memory>

#include "hash.hh"
#include "derivations.hh"

struct BuildProduct
{
    nix::Path path, defaultPath;
    std::string type, subtype, name;
    bool isRegular = false;
    nix::Hash sha1hash, sha256hash;
    off_t fileSize = 0;
    BuildProduct() { }
};

struct BuildResult
{
    /* Whether this build has failed with output, i.e., the build
       finished with exit code 0 but produced a file
       $out/nix-support/failed. */
    bool failed = false;

    std::string releaseName;

    unsigned long long closureSize = 0, size = 0;

    std::list<BuildProduct> products;
};

BuildResult getBuildResult(std::shared_ptr<nix::StoreAPI> store, const nix::Derivation & drv);
