#pragma once

#include "source-accessor.hh"
#include "types.hh"
#include "serialise.hh"
#include "hash.hh"

struct NarMemberData
{
    nix::SourceAccessor::Type type;
    std::optional<uint64_t> fileSize;
    std::optional<std::string> contents;
    std::optional<nix::Hash> sha256;
};

typedef std::map<nix::Path, NarMemberData> NarMemberDatas;

/* Read a NAR from a source and get to some info about every file
   inside the NAR. */
void extractNarData(
    nix::Source & source,
    const nix::Path & prefix,
    NarMemberDatas & members);
