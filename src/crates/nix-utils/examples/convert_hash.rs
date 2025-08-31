use nix_utils::{HashAlgorithm, HashFormat, convert_hash};

fn main() {
    let x = convert_hash(
        "1a4be2fe6b5246aa4ac8987a8a4af34c42a8dd7d08b46ab48516bcc1befbcd83",
        Some(HashAlgorithm::SHA256),
        HashFormat::SRI,
    )
    .unwrap();
    println!("{x}");
}
