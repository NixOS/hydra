fn main() {
    if std::env::var("DOCS_RS").is_ok() {
        return;
    }

    println!("cargo:rerun-if-changed=include/");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/nix.cpp");
    println!("cargo:rerun-if-changed=src/lib.rs");
    println!("cargo:rerun-if-changed=src/hash.rs");
    println!("cargo:rerun-if-changed=src/realisation.rs");
    println!("cargo:rerun-if-changed=src/cxx/");

    let library = pkg_config::probe_library("nix-main").unwrap();
    pkg_config::probe_library("nix-store").unwrap();
    pkg_config::probe_library("nix-util").unwrap();
    pkg_config::probe_library("libsodium").unwrap();

    cxx_build::bridges(["src/lib.rs", "src/hash.rs", "src/realisation.rs"])
        .files([
            "src/nix.cpp",
            "src/cxx/utils.cpp",
            "src/cxx/hash.cpp",
            "src/cxx/realisation.cpp",
        ])
        .flag("-std=c++23")
        .flag("-O2")
        .includes(library.include_paths)
        .compile("nix_utils");
}
