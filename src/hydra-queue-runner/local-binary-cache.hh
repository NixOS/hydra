#pragma once

#include "crypto.hh"
#include "store-api.hh"

namespace nix {

struct NarInfo;

class LocalBinaryCache : public nix::Store
{
private:
    ref<Store> localStore;
    Path binaryCacheDir;

    std::unique_ptr<SecretKey> secretKey;
    std::unique_ptr<PublicKeys> publicKeys;

public:

    LocalBinaryCache(ref<Store> localStore, const Path & binaryCacheDir,
        const Path & secretKeyFile, const Path & publicKeyFile);

private:

    Path narInfoFileFor(const Path & storePath);

    void addToCache(const ValidPathInfo & info, const string & nar);

    NarInfo readNarInfo(const Path & storePath);

public:

    bool isValidPath(const Path & path) override;

    PathSet queryValidPaths(const PathSet & paths) override
    { abort(); }

    PathSet queryAllValidPaths() override
    { abort(); }

    ValidPathInfo queryPathInfo(const Path & path) override;

    Hash queryPathHash(const Path & path) override
    { abort(); }

    void queryReferrers(const Path & path,
        PathSet & referrers) override
    { abort(); }

    Path queryDeriver(const Path & path) override
    { abort(); }

    PathSet queryValidDerivers(const Path & path) override
    { abort(); }

    PathSet queryDerivationOutputs(const Path & path) override
    { abort(); }

    StringSet queryDerivationOutputNames(const Path & path) override
    { abort(); }

    Path queryPathFromHashPart(const string & hashPart) override
    { abort(); }

    PathSet querySubstitutablePaths(const PathSet & paths) override
    { abort(); }

    void querySubstitutablePathInfos(const PathSet & paths,
        SubstitutablePathInfos & infos) override;

    Path addToStore(const string & name, const Path & srcPath,
        bool recursive = true, HashType hashAlgo = htSHA256,
        PathFilter & filter = defaultPathFilter, bool repair = false) override
    { abort(); }

    Path addTextToStore(const string & name, const string & s,
        const PathSet & references, bool repair = false) override
    { abort(); }

    void exportPath(const Path & path, bool sign,
        Sink & sink) override;

    Paths importPaths(bool requireSignature, Source & source) override;

    Path importPath(Source & source);

    void buildPaths(const PathSet & paths, BuildMode buildMode = bmNormal) override;

    BuildResult buildDerivation(const Path & drvPath, const BasicDerivation & drv,
        BuildMode buildMode = bmNormal) override
    { abort(); }

    void ensurePath(const Path & path) override;

    void addTempRoot(const Path & path) override
    { abort(); }

    void addIndirectRoot(const Path & path) override
    { abort(); }

    void syncWithGC() override
    { }

    Roots findRoots() override
    { abort(); }

    void collectGarbage(const GCOptions & options, GCResults & results) override
    { abort(); }

    PathSet queryFailedPaths() override
    { return PathSet(); }

    void clearFailedPaths(const PathSet & paths) override
    { }

    void optimiseStore() override
    { }

    bool verifyStore(bool checkContents, bool repair) override
    { return true; }

};

}
