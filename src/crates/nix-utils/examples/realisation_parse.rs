use fs_err::tokio::read_to_string;
use nix_utils::RealisationOperations as _;

#[tokio::main]
async fn main() {
    let json_str = "{\"dependentRealisations\":{}, \"id\": \"sha256:6e46b9cf4fecaeab4b3c0578f4ab99e89d2f93535878c4ac69b5d5c4eb3a3db9!debug\", \"outPath\": \"5cdp7ncqc47j3ylzqc2lpphgks78p02s-bash-5.2p37-debug\", \"signatures\":[] }";

    let local = nix_utils::LocalStore::init();
    let mut realisation = local.parse_realisation(json_str).unwrap();

    println!("id: {}", realisation.get_id());
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
