use harmonia_store_core::signature::SecretKey;
use nix_utils::RealisationOperations as _;

#[tokio::main]
async fn main() {
    let local = nix_utils::LocalStore::init();
    let id = nix_utils::DrvOutput {
        drv_path: "g1w7hy3qg1w7hy3qg1w7hy3qg1w7hy3q-bash-5.2p37.drv"
            .parse()
            .unwrap(),
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
    realisation.value.sign_mut(&realisation.key, &[sk]);

    println!(
        "json signed: {}",
        serde_json::to_string(&realisation).unwrap()
    );
}
