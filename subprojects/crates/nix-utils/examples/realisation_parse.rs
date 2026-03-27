use harmonia_store_core::signature::SecretKey;
use nix_utils::Realisation;

#[tokio::main]
async fn main() {
    let json_str = r#"{"key": {"drvPath": "g1w7hy3qg1w7hy3qg1w7hy3qg1w7hy3q-bash-5.2p37.drv", "outputName": "debug"}, "value": {"outPath": "5cdp7ncqc47j3ylzqc2lpphgks78p02s-bash-5.2p37-debug", "signatures": []}}"#;

    let mut realisation = serde_json::from_str::<Realisation>(json_str).unwrap();

    println!("id: {}", realisation.key);
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
