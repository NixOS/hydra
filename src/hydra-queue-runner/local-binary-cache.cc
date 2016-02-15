#include "local-binary-cache.hh"

#include "archive.hh"
#include "derivations.hh"
#include "globals.hh"
#include "worker-protocol.hh"

namespace nix {

LocalBinaryCache::LocalBinaryCache(ref<Store> localStore, const Path & binaryCacheDir)
    : localStore(localStore), binaryCacheDir(binaryCacheDir)
{
    createDirs(binaryCacheDir + "/nar");
}

Path LocalBinaryCache::narInfoFileFor(const Path & storePath)
{
    assertStorePath(storePath);
    return binaryCacheDir + "/" + storePathToHash(storePath) + ".narinfo";
}

void atomicWrite(const Path & path, const std::string & s)
{
    Path tmp = path + ".tmp." + std::to_string(getpid());
    AutoDelete del(tmp, false);
    writeFile(tmp, s);
    if (rename(tmp.c_str(), path.c_str()))
        throw SysError(format("renaming ‘%1%’ to ‘%2%’") % tmp % path);
    del.cancel();
}

void LocalBinaryCache::addToCache(const ValidPathInfo & info,
    const string & nar)
{
    size_t narSize = nar.size();
    Hash narHash = hashString(htSHA256, nar);

    if (info.hash.type != htUnknown && info.hash != narHash)
        throw Error(format("refusing to copy corrupted path ‘%1%’ to binary cache") % info.path);

    printMsg(lvlTalkative, format("copying path ‘%1%’ (%2% bytes) to binary cache")
        % info.path % narSize);

    /* Atomically write the NAR file. */
    string narFileRel = "nar/" + printHash(narHash) + ".nar";
    Path narFile = binaryCacheDir + "/" + narFileRel;
    if (!pathExists(narFile)) atomicWrite(narFile, nar);

    /* Atomically write the NAR info file.*/
    Path narInfoFile = narInfoFileFor(info.path);

    if (!pathExists(narInfoFile)) {

        Strings refs;
        for (auto & r : info.references)
            refs.push_back(baseNameOf(r));

        std::string narInfo;
        narInfo += "StorePath: " + info.path + "\n";
        narInfo += "URL: " + narFileRel + "\n";
        narInfo += "Compression: none\n";
        narInfo += "FileHash: sha256:" + printHash(narHash) + "\n";
        narInfo += "FileSize: " + std::to_string(narSize) + "\n";
        narInfo += "NarHash: sha256:" + printHash(narHash) + "\n";
        narInfo += "NarSize: " + std::to_string(narSize) + "\n";
        narInfo += "References: " + concatStringsSep(" ", refs) + "\n";

        // FIXME: add signature

        atomicWrite(narInfoFile, narInfo);
    }
}

LocalBinaryCache::NarInfo LocalBinaryCache::readNarInfo(const Path & storePath)
{
    NarInfo res;

    Path narInfoFile = narInfoFileFor(storePath);
    if (!pathExists(narInfoFile))
        abort();
    std::string narInfo = readFile(narInfoFile);

    auto corrupt = [&]() {
        throw Error(format("corrupt NAR info file ‘%1%’") % narInfoFile);
    };

    size_t pos = 0;
    while (pos < narInfo.size()) {

        size_t colon = narInfo.find(':', pos);
        if (colon == std::string::npos) corrupt();

        std::string name(narInfo, pos, colon - pos);

        size_t eol = narInfo.find('\n', colon + 2);
        if (eol == std::string::npos) corrupt();

        std::string value(narInfo, colon + 2, eol - colon - 2);

        if (name == "StorePath") {
            res.info.path = value;
            if (value != storePath) corrupt();
            res.info.path = value;
        }
        else if (name == "References") {
            auto refs = tokenizeString<Strings>(value, " ");
            if (!res.info.references.empty()) corrupt();
            for (auto & r : refs)
                res.info.references.insert(settings.nixStore + "/" + r);
        }
        else if (name == "URL") {
            res.narUrl = value;
        }

        pos = eol + 1;
    }

    if (res.info.path.empty() || res.narUrl.empty()) corrupt();

    return res;
}

bool LocalBinaryCache::isValidPath(const Path & storePath)
{
    Path narInfoFile = narInfoFileFor(storePath);

    printMsg(lvlDebug, format("checking %1% -> %2%") % storePath % narInfoFile);

    return pathExists(narInfoFile);
}

void LocalBinaryCache::exportPath(const Path & storePath, bool sign, Sink & sink)
{
    assert(!sign);

    auto res = readNarInfo(storePath);

    auto nar = readFile(binaryCacheDir + "/" + res.narUrl);

    printMsg(lvlTalkative, format("exporting path ‘%1%’ (%2% bytes)") % storePath % nar.size());

    assert(nar.size() % 8 == 0);

    sink((unsigned char *) nar.c_str(), nar.size());

    // FIXME: check integrity of NAR.

    sink << exportMagic << storePath << res.info.references << res.info.deriver << 0;
}

Paths LocalBinaryCache::importPaths(bool requireSignature, Source & source)
{
    assert(!requireSignature);
    Paths res;
    while (true) {
        unsigned long long n = readLongLong(source);
        if (n == 0) break;
        if (n != 1) throw Error("input doesn't look like something created by ‘nix-store --export’");
        res.push_back(importPath(source));
    }
    return res;
}

struct TeeSource : Source
{
    Source & readSource;
    std::string data;
    TeeSource(Source & readSource) : readSource(readSource)
    {
    }
    size_t read(unsigned char * data, size_t len)
    {
        size_t n = readSource.read(data, len);
        this->data.append((char *) data, n);
        return n;
    }
};

struct NopSink : ParseSink
{
};

Path LocalBinaryCache::importPath(Source & source)
{
    /* FIXME: some cut&paste of LocalStore::importPath(). */

    /* Extract the NAR from the source. */
    TeeSource tee(source);
    NopSink sink;
    parseDump(sink, tee);

    uint32_t magic = readInt(source);
    if (magic != exportMagic)
        throw Error("Nix archive cannot be imported; wrong format");

    ValidPathInfo info;
    info.path = readStorePath(source);

    info.references = readStorePaths<PathSet>(source);

    readString(source); // deriver, don't care

    bool haveSignature = readInt(source) == 1;
    assert(!haveSignature);

    addToCache(info, tee.data);

    return info.path;
}

ValidPathInfo LocalBinaryCache::queryPathInfo(const Path & storePath)
{
    return readNarInfo(storePath).info;
}

void LocalBinaryCache::querySubstitutablePathInfos(const PathSet & paths,
    SubstitutablePathInfos & infos)
{
    PathSet left;

    for (auto & storePath : paths) {
        if (!localStore->isValidPath(storePath)) {
            left.insert(storePath);
            continue;
        }
        ValidPathInfo info = localStore->queryPathInfo(storePath);
        SubstitutablePathInfo sub;
        sub.references = info.references;
        sub.downloadSize = 0;
        sub.narSize = info.narSize;
        infos.emplace(storePath, sub);
    }

    localStore->querySubstitutablePathInfos(left, infos);
}

void LocalBinaryCache::buildPaths(const PathSet & paths, BuildMode buildMode)
{
    for (auto & storePath : paths) {
        assert(!isDerivation(storePath));

        if (isValidPath(storePath)) continue;

        localStore->addTempRoot(storePath);

        if (!localStore->isValidPath(storePath))
            localStore->ensurePath(storePath);

        ValidPathInfo info = localStore->queryPathInfo(storePath);

        for (auto & ref : info.references)
            if (ref != storePath)
                ensurePath(ref);

        StringSink sink;
        dumpPath(storePath, sink);

        addToCache(info, sink.s);
    }
}

void LocalBinaryCache::ensurePath(const Path & path)
{
    buildPaths({path});
}

}
