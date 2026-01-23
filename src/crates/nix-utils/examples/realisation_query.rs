use fs_err::tokio::read_to_string;
use nix_utils::RealisationOperations as _;

#[tokio::main]
async fn main() {
    let local = nix_utils::LocalStore::init();
    let mut realisation = local
        .query_raw_realisation(
            "sha256:6e46b9cf4fecaeab4b3c0578f4ab99e89d2f93535878c4ac69b5d5c4eb3a3db9",
            "debug",
        )
        .unwrap();

    println!("json: {}", realisation.as_json());
    println!("fingerprint: {}", realisation.fingerprint());
    println!(
        "struct: {:?}",
        realisation.as_rust(local.as_base_store()).unwrap()
    );

    realisation
        .sign(
            &read_to_string(format!(
                "{}/../../example-secret-key",
                env!("CARGO_MANIFEST_DIR")
            ))
            .await
            .unwrap(),
        )
        .unwrap();
    println!("json signed: {:?}", realisation.as_json());
}
