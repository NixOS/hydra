fn main() {
    let _store = nix_utils::LocalStore::init();
    println!("Nix prefix: {}", nix_utils::get_nix_prefix());
    println!("Store dir: {}", nix_utils::get_store_dir());
    println!("Log dir: {}", nix_utils::get_log_dir());
    println!("State dir: {}", nix_utils::get_state_dir());
    println!("System: {}", nix_utils::get_this_system());
    println!("Extra Platforms: {:?}", nix_utils::get_extra_platforms());
    println!("System features: {:?}", nix_utils::get_system_features());
    println!("Use cgroups: {}", nix_utils::get_use_cgroups());
}
