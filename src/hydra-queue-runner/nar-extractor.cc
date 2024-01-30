#include "nar-extractor.hh"

#include "archive.hh"

#include <unordered_set>

using namespace nix;


struct NarMemberConstructor : CreateRegularFileSink
{
    NarMemberData & curMember;

    HashSink hashSink = HashSink { HashAlgorithm::SHA256 };

    std::optional<uint64_t> expectedSize;

    NarMemberConstructor(NarMemberData & curMember)
        : curMember(curMember)
    { }

    void isExecutable() override
    {
    }

    void preallocateContents(uint64_t size) override
    {
        expectedSize = size;
    }

    void operator () (std::string_view data) override
    {
        assert(expectedSize);
        *curMember.fileSize += data.size();
        hashSink(data);
        if (curMember.contents) {
            curMember.contents->append(data);
        }
        assert(curMember.fileSize <= expectedSize);
        if (curMember.fileSize == expectedSize) {
            auto [hash, len] = hashSink.finish();
            assert(curMember.fileSize == len);
            curMember.sha256 = hash;
        }
    }
};

struct Extractor : FileSystemObjectSink
{
    std::unordered_set<Path> filesToKeep {
        "/nix-support/hydra-build-products",
        "/nix-support/hydra-release-name",
        "/nix-support/hydra-metrics",
    };

    NarMemberDatas & members;
    Path prefix;

    Extractor(NarMemberDatas & members, const Path & prefix)
        : members(members), prefix(prefix)
    { }

    void createDirectory(const Path & path) override
    {
        members.insert_or_assign(prefix + path, NarMemberData { .type = SourceAccessor::Type::tDirectory });
    }

    void createRegularFile(const Path & path, std::function<void(CreateRegularFileSink &)> func) override
    {
        NarMemberConstructor nmc {
            members.insert_or_assign(prefix + path, NarMemberData {
                .type = SourceAccessor::Type::tRegular,
                .fileSize = 0,
                .contents = filesToKeep.count(path) ? std::optional("") : std::nullopt,
            }).first->second,
        };
        func(nmc);
    }

    void createSymlink(const Path & path, const std::string & target) override
    {
        members.insert_or_assign(prefix + path, NarMemberData { .type = SourceAccessor::Type::tSymlink });
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
