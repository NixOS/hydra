fn main() {
    if std::env::var("DOCS_RS").is_ok() {
        return;
    }

    println!("cargo:rerun-if-changed=include/nix.h");
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/nix.cpp");
    println!("cargo:rerun-if-changed=src/lib.rs");

    let library = pkg_config::probe_library("nix-main").unwrap();
    pkg_config::probe_library("nix-store").unwrap();
    pkg_config::probe_library("nix-util").unwrap();
    pkg_config::probe_library("libsodium").unwrap();

    cxx_build::bridge("src/lib.rs")
        .file("src/nix.cpp")
        .flag("-std=c++2a")
        .flag("-O2")
        .includes(library.include_paths)
        .compile("nix_utils");
}
