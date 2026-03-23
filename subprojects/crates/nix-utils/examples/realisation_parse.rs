use harmonia_store_core::signature::SecretKey;
use nix_utils::Realisation;

#[tokio::main]
async fn main() {
    let json_str = r#"{"dependentRealisations":{}, "id": "sha256:6e46b9cf4fecaeab4b3c0578f4ab99e89d2f93535878c4ac69b5d5c4eb3a3db9!debug", "outPath": "5cdp7ncqc47j3ylzqc2lpphgks78p02s-bash-5.2p37-debug", "signatures":[] }"#;

    let mut realisation = serde_json::from_str::<Realisation>(json_str).unwrap();

    println!("id: {}", realisation.id);
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

    println!("json signed: {}", serde_json::to_string(&realisation).unwrap());
}
