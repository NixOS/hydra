#include "nar-extractor.hh"

#include "archive.hh"

#include <unordered_set>

using namespace nix;

struct Extractor : ParseSink
{
    std::unordered_set<Path> filesToKeep {
        "/nix-support/hydra-build-products",
        "/nix-support/hydra-release-name",
        "/nix-support/hydra-metrics",
    };

    NarMemberDatas & members;
    NarMemberData * curMember = nullptr;
    Path prefix;

    Extractor(NarMemberDatas & members, const Path & prefix)
        : members(members), prefix(prefix)
    { }

    void createDirectory(const Path & path) override
    {
        members.insert_or_assign(prefix + path, NarMemberData { .type = FSAccessor::Type::tDirectory });
    }

    void createRegularFile(const Path & path) override
    {
        curMember = &members.insert_or_assign(prefix + path, NarMemberData {
            .type = FSAccessor::Type::tRegular,
            .fileSize = 0,
            .contents = filesToKeep.count(path) ? std::optional("") : std::nullopt,
        }).first->second;
    }

    std::optional<uint64_t> expectedSize;
    std::unique_ptr<HashSink> hashSink;

    void preallocateContents(uint64_t size) override
    {
        expectedSize = size;
        hashSink = std::make_unique<HashSink>(htSHA256);
    }

    void receiveContents(std::string_view data) override
    {
        assert(expectedSize);
        assert(curMember);
        assert(hashSink);
        *curMember->fileSize += data.size();
        (*hashSink)(data);
        if (curMember->contents) {
            curMember->contents->append(data);
        }
        assert(curMember->fileSize <= expectedSize);
        if (curMember->fileSize == expectedSize) {
            auto [hash, len] = hashSink->finish();
            assert(curMember->fileSize == len);
            curMember->sha256 = hash;
            hashSink.reset();
        }
    }

    void createSymlink(const Path & path, const string & target) override
    {
        members.insert_or_assign(prefix + path, NarMemberData { .type = FSAccessor::Type::tSymlink });
    }
};


void extractNarData(
    Source & source,
    const Path & prefix,
    NarMemberDatas & members)
{
    Extractor extractor(members, prefix);
    parseDump(extractor, source);
    // Note: this point may not be reached if we're in a coroutine.
}
