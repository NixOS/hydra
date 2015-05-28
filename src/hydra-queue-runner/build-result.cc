#include "build-result.hh"
#include "store-api.hh"
#include "misc.hh"
#include "util.hh"

using namespace nix;


BuildResult getBuildResult(const Derivation & drv)
{
    BuildResult res;

    /* Compute the closure size. */
    PathSet outputs;
    for (auto & output : drv.outputs)
        outputs.insert(output.second.path);
    PathSet closure;
    for (auto & output : outputs)
        computeFSClosure(*store, output, closure);
    for (auto & path : closure) {
        auto info = store->queryPathInfo(path);
        res.closureSize += info.narSize;
        if (outputs.find(path) != outputs.end()) res.size += info.narSize;
    }

    /* Get build products. */
    bool explicitProducts = false;

    for (auto & output : outputs) {
        Path productsFile = output + "/nix-support/hydra-build-products";
        if (!pathExists(productsFile)) continue;
        explicitProducts = true;

        /* For security, resolve symlinks. */
        productsFile = canonPath(productsFile, true);
        if (!isInStore(productsFile)) continue;

        // FIXME: handle I/O errors

        auto contents = readFile(productsFile);
        auto lines = tokenizeString<Strings>(contents, "\n");

        for (auto & line : lines) {
            BuildProduct product;

            auto words = tokenizeString<Strings>(line);
            if (words.size() < 3) continue;
            product.type = words.front(); words.pop_front();
            product.subtype = words.front(); words.pop_front();
            if (string(words.front(), 0, 1) == "\"") {
                // FIXME:
                throw Error("FIXME");
            } else {
                product.path = words.front(); words.pop_front();
            }
            product.defaultPath = words.empty() ? "" : words.front();

            /*  Ensure that the path exists and points into the
                Nix store. */
            if (product.path == "" || product.path[0] != '/') continue;
            product.path = canonPath(product.path, true);
            if (!isInStore(product.path) || !pathExists(product.path)) continue;

            /*  FIXME: check that the path is in the input closure
                of the build? */

            product.name = product.path == output ? "" : baseNameOf(product.path);

            struct stat st;
            if (stat(product.path.c_str(), &st))
                throw SysError(format("getting status of ‘%1%’") % product.path);

            if (S_ISREG(st.st_mode)) {
                product.isRegular = true;
                product.fileSize = st.st_size;
                product.sha1hash = hashFile(htSHA1, product.path);
                product.sha256hash = hashFile(htSHA256, product.path);
            }

            res.products.push_back(product);
        }
    }

    /* If no build products were explicitly declared, then add all
       outputs as a product of type "nix-build". */
    if (!explicitProducts) {
        for (auto & output : drv.outputs) {
            BuildProduct product;
            product.path = output.second.path;
            product.type = "nix-build";
            product.subtype = output.first == "out" ? "" : output.first;
            product.name = storePathToName(product.path);

            struct stat st;
            if (stat(product.path.c_str(), &st))
                throw SysError(format("getting status of ‘%1%’") % product.path);
            if (S_ISDIR(st.st_mode))
                res.products.push_back(product);
        }
    }

    /* Get the release name from $output/nix-support/hydra-release-name. */
    for (auto & output : outputs) {
        Path p = output + "/nix-support/hydra-release-name";
        if (!pathExists(p)) continue;
        // FIXME: handle I/O error
        res.releaseName = trim(readFile(p));
        // FIXME: validate release name
    }

    return res;
}
