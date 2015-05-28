#pragma once

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
    std::string releaseName;

    unsigned long long closureSize = 0, size = 0;

    std::list<BuildProduct> products;
};

BuildResult getBuildResult(const nix::Derivation & drv);
