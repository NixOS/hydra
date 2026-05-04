fn main() {
    let _store = nix_utils::LocalStore::init();
    println!("Store dir: {}", nix_utils::get_store_dir());
    println!("State dir: {}", nix_utils::get_state_dir());
    println!("System: {}", nix_utils::get_this_system());
    println!("Extra Platforms: {:?}", nix_utils::get_extra_platforms());
    println!("System features: {:?}", nix_utils::get_system_features());
    println!("Substituters: {:?}", nix_utils::get_substituters());
    println!("Use cgroups: {}", nix_utils::get_use_cgroups());
}
