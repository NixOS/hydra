#include "build-result.hh"
#include "store-api.hh"
#include "util.hh"
#include "fs-accessor.hh"

#include <regex>

using namespace nix;


BuildOutput getBuildOutput(nix::ref<Store> store,
    nix::ref<nix::FSAccessor> accessor, const Derivation & drv)
{
    BuildOutput res;

    /* Compute the closure size. */
    auto outputs = drv.outputPaths();
    StorePathSet closure;
    for (auto & output : outputs)
        store->computeFSClosure(output, closure);
    for (auto & path : closure) {
        auto info = store->queryPathInfo(path);
        res.closureSize += info->narSize;
        if (outputs.count(path)) res.size += info->narSize;
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

        Path failedFile = outputS + "/nix-support/failed";
        if (accessor->stat(failedFile).type == FSAccessor::Type::tRegular)
            res.failed = true;

        Path productsFile = outputS + "/nix-support/hydra-build-products";
        if (accessor->stat(productsFile).type != FSAccessor::Type::tRegular)
            continue;

        explicitProducts = true;

        for (auto & line : tokenizeString<Strings>(accessor->readFile(productsFile), "\n")) {
            BuildProduct product;

            std::smatch match;
            if (!std::regex_match(line, match, regex)) continue;

            product.type = match[1];
            product.subtype = match[2];
            std::string s(match[3]);
            product.path = s[0] == '"' ? string(s, 1, s.size() - 2) : s;
            product.defaultPath = match[5];

            /* Ensure that the path exists and points into the Nix
               store. */
            // FIXME: should we disallow products referring to other
            // store paths, or that are outside the input closure?
            if (product.path == "" || product.path[0] != '/') continue;
            product.path = canonPath(product.path);
            if (!store->isInStore(product.path)) continue;

            auto st = accessor->stat(product.path);
            if (st.type == FSAccessor::Type::tMissing) continue;

            product.name = product.path == store->printStorePath(output) ? "" : baseNameOf(product.path);

            if (st.type == FSAccessor::Type::tRegular) {
                product.isRegular = true;
                product.fileSize = st.fileSize;
                auto contents = accessor->readFile(product.path);
                product.sha1hash = hashString(htSHA1, contents);
                product.sha256hash = hashString(htSHA256, contents);
            }

            res.products.push_back(product);
        }
    }

    /* If no build products were explicitly declared, then add all
       outputs as a product of type "nix-build". */
    if (!explicitProducts) {
        for (auto & output : drv.outputs) {
            BuildProduct product;
            product.path = store->printStorePath(output.second.path);
            product.type = "nix-build";
            product.subtype = output.first == "out" ? "" : output.first;
            product.name = output.second.path.name();

            auto st = accessor->stat(product.path);
            if (st.type == FSAccessor::Type::tMissing)
                throw Error("getting status of ‘%s’", product.path);
            if (st.type == FSAccessor::Type::tDirectory)
                res.products.push_back(product);
        }
    }

    /* Get the release name from $output/nix-support/hydra-release-name. */
    for (auto & output : outputs) {
        auto p = store->printStorePath(output) + "/nix-support/hydra-release-name";
        if (accessor->stat(p).type != FSAccessor::Type::tRegular) continue;
        try {
            res.releaseName = trim(accessor->readFile(p));
        } catch (Error & e) { continue; }
        // FIXME: validate release name
    }

    /* Get metrics. */
    for (auto & output : outputs) {
        auto metricsFile = store->printStorePath(output) + "/nix-support/hydra-metrics";
        if (accessor->stat(metricsFile).type != FSAccessor::Type::tRegular) continue;
        for (auto & line : tokenizeString<Strings>(accessor->readFile(metricsFile), "\n")) {
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
