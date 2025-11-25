use nix_utils::BaseStore as _;

fn main() {
    let local = nix_utils::LocalStore::init();

    let p1 = nix_utils::StorePath::new("ihl4ya67glh9815v1lanyqph0p7hdzfb-hdf5-cpp-1.14.6-bin");
    let p2 = nix_utils::StorePath::new("sgv5w811jvvxpjgmyw1n6l8hwfilha7x-hdf5-cpp-1.14.6-dev");
    let p3 = nix_utils::StorePath::new("vb6yrzk31ng8s6nzs4y4jq6qsjab3gxv-hdf5-cpp-1.14.6");

    let infos = local.query_path_infos(&[&p1, &p2, &p3]);

    println!("{infos:?}");
    println!("closure_size {p1}: {}", local.compute_closure_size(&p1));
    println!("closure_size {p2}: {}", local.compute_closure_size(&p2));
    println!("closure_size {p3}: {}", local.compute_closure_size(&p3));

    println!("stats: {:?}", local.get_store_stats());
}
