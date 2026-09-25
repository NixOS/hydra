#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/* Prevent a clash between some Perl and libstdc++ macros. */
#undef do_open
#undef do_close

#include "nix/store/derivations.hh"
#include "nix/store/globals.hh"
#include "nix/store/store-open.hh"
#include "nix/util/source-accessor.hh"

using namespace nix;

static bool libStoreInitialized = false;

/* The bindings speak base names, not full paths: the store directory is
   Perl's business. These are the only two places that boundary is
   crossed. */
static StorePath toStorePath(SV * sv)
{
    STRLEN len;
    /* Honours overloaded stringification, so a Nix::StorePath object and a
       bare base name are both accepted. */
    const char * p = SvPV(sv, len);
    /* This runs from the typemap, outside any function body, so it has to do
       its own catching: an escaping exception would abort the process rather
       than raise a Perl error. */
    try {
        return StorePath{std::string_view{p, len}};
    } catch (Error & e) {
        croak("%s", e.what());
    }
}

static SV * newSVStorePath(const StorePath & path)
{
    auto s = path.to_string();
    SV * rv = newRV_noinc(newSVpv(s.data(), s.size()));
    return sv_bless(rv, gv_stashpv("Nix::StorePath", GV_ADD));
}

struct StoreWrapper {
    ref<Store> store;
};

MODULE = Nix::Store PACKAGE = Nix::Store
PROTOTYPES: ENABLE

TYPEMAP: <<HERE
StoreWrapper *      O_OBJECT
StorePath           T_STOREPATH

OUTPUT
O_OBJECT
    sv_setref_pv( $arg, CLASS, (void*)$var );

T_STOREPATH
    $arg = newSVStorePath($var);

INPUT
O_OBJECT
    if ( sv_isobject($arg) && (SvTYPE(SvRV($arg)) == SVt_PVMG) ) {
        $var = ($type)SvIV((SV*)SvRV( $arg ));
    }
    else {
        warn( \"${Package}::$func_name() -- \"
		\"$var not a blessed SV reference\");
        XSRETURN_UNDEF;
    }

T_STOREPATH
    $var = toStorePath($arg);
HERE

#undef dNOOP // Hack to work around "error: declaration of 'Perl___notused' has a different language linkage" error message on clang.
#define dNOOP

void
StoreWrapper::DESTROY()

StoreWrapper *
StoreWrapper::new(char * s = nullptr)
    CODE:
        static std::shared_ptr<Store> _store;
        try {
            if (!libStoreInitialized) {
                initLibStore();
                libStoreInitialized = true;
            }
            if (items == 1) {
                _store = openStore();
                RETVAL = new StoreWrapper {
                    .store = ref<Store>{_store}
                };
            } else {
                RETVAL = new StoreWrapper {
                    .store = openStore(s)
                };
            }
        } catch (Error & e) {
            croak("%s", e.what());
        }
    OUTPUT:
        RETVAL


void init()
    CODE:
        if (!libStoreInitialized) {
            initLibStore();
            libStoreInitialized = true;
        }


int
StoreWrapper::isValidPath(StorePath path)
    CODE:
        try {
            RETVAL = THIS->store->isValidPath(path);
        } catch (Error & e) {
            croak("%s", e.what());
        }
    OUTPUT:
        RETVAL


SV *
StoreWrapper::queryReferences(StorePath path)
    PPCODE:
        try {
            for (auto & i : THIS->store->queryPathInfo(path)->references)
                XPUSHs(sv_2mortal(newSVStorePath(i)));
        } catch (Error & e) {
            croak("%s", e.what());
        }


SV *
StoreWrapper::queryPathHash(StorePath path)
    PPCODE:
        try {
            auto s = THIS->store->queryPathInfo(path)->narHash.to_string(HashFormat::Nix32, true);
            XPUSHs(sv_2mortal(newSVpv(s.c_str(), 0)));
        } catch (Error & e) {
            croak("%s", e.what());
        }


SV *
StoreWrapper::queryPathInfo(StorePath path, int base32)
    PPCODE:
        try {
            auto info = THIS->store->queryPathInfo(path);
            if (!info->deriver)
                XPUSHs(&PL_sv_undef);
            else
                XPUSHs(sv_2mortal(newSVStorePath(*info->deriver)));
            auto s = info->narHash.to_string(base32 ? HashFormat::Nix32 : HashFormat::Base16, true);
            XPUSHs(sv_2mortal(newSVpv(s.c_str(), 0)));
            mXPUSHi(info->registrationTime);
            mXPUSHi(info->narSize);
            AV * refs = newAV();
            for (auto & i : info->references)
                av_push(refs, newSVStorePath(i));
            XPUSHs(sv_2mortal(newRV((SV *) refs)));
            AV * sigs = newAV();
            for (auto & i : info->sigs)
                av_push(sigs, newSVpv(i.to_string().c_str(), 0));
            XPUSHs(sv_2mortal(newRV((SV *) sigs)));
        } catch (Error & e) {
            croak("%s", e.what());
        }


SV *
StoreWrapper::queryPathFromHashPart(char * hashPart)
    PPCODE:
        try {
            auto path = THIS->store->queryPathFromHashPart(hashPart);
            XPUSHs(sv_2mortal(path ? newSVStorePath(*path) : newSVpv("", 0)));
        } catch (Error & e) {
            croak("%s", e.what());
        }


SV *
StoreWrapper::computeFSClosure(int flipDirection, int includeOutputs, ...)
    PPCODE:
        try {
            StorePathSet paths;
            for (int n = 3; n < items; ++n)
                THIS->store->computeFSClosure(toStorePath(ST(n)), paths, flipDirection, includeOutputs);
            for (auto & i : paths)
                XPUSHs(sv_2mortal(newSVStorePath(i)));
        } catch (Error & e) {
            croak("%s", e.what());
        }


SV *
StoreWrapper::topoSortPaths(...)
    PPCODE:
        try {
            StorePathSet paths;
            for (int n = 1; n < items; ++n) paths.insert(toStorePath(ST(n)));
            auto sorted = THIS->store->topoSortPaths(paths);
            for (auto & i : sorted)
                XPUSHs(sv_2mortal(newSVStorePath(i)));
        } catch (Error & e) {
            croak("%s", e.what());
        }


SV * signString(char * secretKey_, char * msg)
    PPCODE:
        try {
            auto sig = SecretKey(secretKey_).signDetached(msg).to_string();
            XPUSHs(sv_2mortal(newSVpv(sig.c_str(), sig.size())));
        } catch (Error & e) {
            croak("%s", e.what());
        }


SV *
StoreWrapper::addToStore(char * srcPath, int recursive, char * algo)
    PPCODE:
        try {
            auto method = recursive ? ContentAddressMethod::Raw::NixArchive : ContentAddressMethod::Raw::Flat;
            auto path = THIS->store->addToStore(
                std::string(baseNameOf(srcPath)),
                {makeFSSourceAccessor(absPath(srcPath)), CanonPath::root},
                method, parseHashAlgo(algo));
            XPUSHs(sv_2mortal(newSVStorePath(path)));
        } catch (Error & e) {
            croak("%s", e.what());
        }


SV *
StoreWrapper::derivationSystem(StorePath drvPath)
    CODE:
        try {
            Derivation drv = THIS->store->derivationFromPath(drvPath);
            RETVAL = newSVpv(drv.platform.c_str(), 0);
        } catch (Error & e) {
            croak("%s", e.what());
        }
    OUTPUT:
        RETVAL


void
StoreWrapper::addTempRoot(StorePath storePath)
    PPCODE:
        try {
            THIS->store->addTempRoot(storePath);
        } catch (Error & e) {
            croak("%s", e.what());
        }


SV *
StoreWrapper::storeDir()
    PPCODE:
        XPUSHs(sv_2mortal(newSVpv(THIS->store->storeDir.c_str(), 0)));
