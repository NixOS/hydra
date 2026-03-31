use harmonia_store_core::signature::SecretKey;
use nix_utils::RealisationOperations as _;

#[tokio::main]
async fn main() {
    let local = nix_utils::LocalStore::init();
    let id = nix_utils::DrvOutput {
        drv_hash:    "sha256:6e46b9cf4fecaeab4b3c0578f4ab99e89d2f93535878c4ac69b5d5c4eb3a3db9"
            .parse::<harmonia_utils_hash::fmt::Any<harmonia_utils_hash::Hash>>()
            .unwrap()
            .into_hash(),
        output_name: "debug".parse().unwrap(),
    };
    let raw = local.query_raw_realisation(&id).unwrap();
    let mut realisation = raw.as_rust().unwrap();

    println!("json: {}", serde_json::to_string(&realisation).unwrap());
    println!("realisation: {realisation:?}");

    let key_str = fs_err::tokio::read_to_string(format!(
        "{}/../../example-secret-key",
        env!("CARGO_MANIFEST_DIR")
    ))
    .await
    .unwrap();
    let sk = key_str.trim().parse::<SecretKey>().unwrap();
    realisation.sign(&[sk]);

    println!(
        "json signed: {}",
        serde_json::to_string(&realisation).unwrap()
    );
}
