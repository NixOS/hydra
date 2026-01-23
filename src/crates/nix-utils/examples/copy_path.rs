use nix_utils::{self, copy_paths};

// requires env vars: AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY

#[tokio::main]
async fn main() {
    let local = nix_utils::LocalStore::init();
    let remote =
        nix_utils::RemoteStore::init("s3://store?region=unknown&endpoint=http://localhost:9000");
    nix_utils::set_verbosity(1);

    let res = copy_paths(
        local.as_base_store(),
        remote.as_base_store(),
        &[nix_utils::StorePath::new(
            "1r5zv195y7b7b5q2daf5p82s2m6r4rg4-CVE-2024-56406.patch",
        )],
        false,
        false,
        false,
    )
    .await;
    println!("copy res={res:?}");

    let stats = remote.get_s3_stats().unwrap();
    println!("stats {stats:?}");
}
