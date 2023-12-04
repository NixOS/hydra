#include "hydra-build-result.hh"
#include "store-api.hh"
#include "util.hh"
#include "source-accessor.hh"

#include <regex>

using namespace nix;


BuildOutput getBuildOutput(
    nix::ref<Store> store,
    NarMemberDatas & narMembers,
    const Derivation & drv)
{
    BuildOutput res;

    /* Compute the closure size. */
    StorePathSet outputs;
    StorePathSet closure;
    for (auto & i : drv.outputsAndOptPaths(*store))
        if (i.second.second) {
            store->computeFSClosure(*i.second.second, closure);
            outputs.insert(*i.second.second);
        }
    for (auto & path : closure) {
        auto info = store->queryPathInfo(path);
        res.closureSize += info->narSize;
        if (outputs.count(path)) res.size += info->narSize;
    }

    /* Fetch missing data. Usually buildRemote() will have extracted
       this data from the incoming NARs. */
    for (auto & output : outputs) {
        auto outputS = store->printStorePath(output);
        if (!narMembers.count(outputS)) {
            printInfo("fetching NAR contents of '%s'...", outputS);
            auto source = sinkToSource([&](Sink & sink)
            {
                store->narFromPath(output, sink);
            });
            extractNarData(*source, outputS, narMembers);
        }
    }

    /* Get build products. */
    bool explicitProducts = false;

    std::regex regex(
        "([a-zA-Z0-9_-]+)" // type (e.g. "doc")
        "[[:space:]]+"
        "([a-zA-Z0-9_-]+)" // subtype (e.g. "readme")
        "[[:space:]]+"
        "(\"[^\"]+\"|[^[:space:]\"]+)" // path (may be quoted)
        "([[:space:]]+([^[:space:]]+))?" // entry point
        , std::regex::extended);

    for (auto & output : outputs) {
        auto outputS = store->printStorePath(output);

        if (narMembers.count(outputS + "/nix-support/failed"))
            res.failed = true;

        auto productsFile = narMembers.find(outputS + "/nix-support/hydra-build-products");
        if (productsFile == narMembers.end() ||
            productsFile->second.type != SourceAccessor::Type::tRegular)
            continue;
        assert(productsFile->second.contents);

        explicitProducts = true;

        for (auto & line : tokenizeString<Strings>(productsFile->second.contents.value(), "\n")) {
            BuildProduct product;

            std::smatch match;
            if (!std::regex_match(line, match, regex)) continue;

            product.type = match[1];
            product.subtype = match[2];
            std::string s(match[3]);
            product.path = s[0] == '"' ? std::string(s, 1, s.size() - 2) : s;
            product.defaultPath = match[5];

            /* Ensure that the path exists and points into the Nix
               store. */
            // FIXME: should we disallow products referring to other
            // store paths, or that are outside the input closure?
            if (product.path == "" || product.path[0] != '/') continue;
            product.path = canonPath(product.path);
            if (!store->isInStore(product.path)) continue;

            auto file = narMembers.find(product.path);
            if (file == narMembers.end()) continue;

            product.name = product.path == store->printStorePath(output) ? "" : baseNameOf(product.path);

            if (file->second.type == SourceAccessor::Type::tRegular) {
                product.isRegular = true;
                product.fileSize = file->second.fileSize.value();
                product.sha256hash = file->second.sha256.value();
            }

            res.products.push_back(product);
        }
    }

    /* If no build products were explicitly declared, then add all
       outputs as a product of type "nix-build". */
    if (!explicitProducts) {
        for (auto & [name, output] : drv.outputs) {
            BuildProduct product;
            auto outPath = output.path(*store, drv.name, name);
            product.path = store->printStorePath(*outPath);
            product.type = "nix-build";
            product.subtype = name == "out" ? "" : name;
            product.name = outPath->name();

            auto file = narMembers.find(product.path);
            assert(file != narMembers.end());
            if (file->second.type == SourceAccessor::Type::tDirectory)
                res.products.push_back(product);
        }
    }

    /* Get the release name from $output/nix-support/hydra-release-name. */
    for (auto & output : outputs) {
        auto file = narMembers.find(store->printStorePath(output) + "/nix-support/hydra-release-name");
        if (file == narMembers.end() ||
            file->second.type != SourceAccessor::Type::tRegular)
            continue;
        res.releaseName = trim(file->second.contents.value());
        // FIXME: validate release name
    }

    /* Get metrics. */
    for (auto & output : outputs) {
        auto file = narMembers.find(store->printStorePath(output) + "/nix-support/hydra-metrics");
        if (file == narMembers.end() ||
            file->second.type != SourceAccessor::Type::tRegular)
            continue;
        for (auto & line : tokenizeString<Strings>(file->second.contents.value(), "\n")) {
            auto fields = tokenizeString<std::vector<std::string>>(line);
            if (fields.size() < 2) continue;
            BuildMetric metric;
            metric.name = fields[0]; // FIXME: validate
            metric.value = atof(fields[1].c_str()); // FIXME
            metric.unit = fields.size() >= 3 ? fields[2] : "";
            res.metrics[metric.name] = metric;
        }
    }

    return res;
}
