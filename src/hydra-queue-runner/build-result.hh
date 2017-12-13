#pragma once

#include <memory>

#include "hash.hh"
#include "derivations.hh"
#include "store-api.hh"

struct BuildProduct
{
    nix::Path path, defaultPath;
    std::string type, subtype, name;
    bool isRegular = false;
    nix::Hash sha1hash, sha256hash;
    off_t fileSize = 0;
    BuildProduct() { }
};

struct BuildMetric
{
    std::string name, unit;
    double value;
};

struct BuildOutput
{
    /* Whether this build has failed with output, i.e., the build
       finished with exit code 0 but produced a file
       $out/nix-support/failed. */
    bool failed = false;

    /* Whether this build has marked itself as aborted, i.e., the build
       finished with exit code 0 but produced a file
       $out/nix-support/aborted. */
    bool aborted = false;

    std::string releaseName;

    unsigned long long closureSize = 0, size = 0;

    std::list<BuildProduct> products;

    std::map<std::string, BuildMetric> metrics;
};

BuildOutput getBuildOutput(nix::ref<nix::Store> store,
    nix::ref<nix::FSAccessor> accessor, const nix::Derivation & drv);
