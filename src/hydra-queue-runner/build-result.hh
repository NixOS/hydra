#pragma once

#include <memory>

#include "hash.hh"
#include "derivations.hh"
#include "store-api.hh"
#include "nar-extractor.hh"

struct BuildProduct
{
    nix::Path path, defaultPath;
    std::string type, subtype, name;
    bool isRegular = false;
    std::optional<nix::Hash> sha256hash;
    std::optional<off_t> fileSize;
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

    std::string releaseName;

    uint64_t closureSize = 0, size = 0;

    std::list<BuildProduct> products;

    std::map<std::string, BuildMetric> metrics;
};

BuildOutput getBuildOutput(
    nix::ref<nix::Store> store,
    NarMemberDatas & narMembers,
    const nix::StorePath & drvPath);
