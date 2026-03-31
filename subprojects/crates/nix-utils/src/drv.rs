use std::collections::BTreeMap;

use harmonia_store_core::derived_path::OutputName;
use harmonia_store_core::store_path::{StoreDir, StorePathName};

pub use harmonia_store_core::derivation::Derivation;

use crate::StorePath;

pub(crate) fn parse_drv(
    store_dir: &StoreDir,
    drv_path: &StorePath,
    input: &str,
) -> Result<Derivation, crate::Error> {
    let drv_name_str = drv_path.name().to_string();
    let name: StorePathName = drv_name_str
        .strip_suffix(".drv")
        .ok_or_else(|| anyhow::anyhow!("derivation path must end in .drv: {drv_name_str}"))?
        .parse()
        .map_err(|e| anyhow::anyhow!("invalid derivation name: {e}"))?;

    harmonia_store_aterm::parse_derivation_aterm(store_dir, input, name)
        .map_err(|e| anyhow::anyhow!("ATerm parse error: {e}").into())
}

#[tracing::instrument(skip(store), fields(%drv), err)]
pub async fn query_drv(
    store: &crate::LocalStore,
    drv: &StorePath,
) -> Result<Option<Derivation>, crate::Error> {
    use crate::BaseStore as _;

    if !drv.is_derivation() {
        return Ok(None);
    }

    let full_path = store.print_store_path(drv);
    if !fs_err::tokio::try_exists(&full_path).await? {
        return Ok(None);
    }

    let input = fs_err::tokio::read_to_string(&full_path).await?;
    Ok(Some(parse_drv(store.get_store_dir(), drv, &input)?))
}

/// Resolve output paths for all outputs. Returns `None` for outputs whose
/// paths cannot be determined before building (`Deferred`, `CAFloating`, `Impure`).
pub fn output_paths(
    drv: &Derivation,
    store_dir: &StoreDir,
) -> BTreeMap<OutputName, Option<StorePath>> {
    drv.outputs
        .iter()
        .map(|(name, output)| {
            let path = output.path(store_dir, &drv.name, name).ok().flatten();
            (name.clone(), path)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use harmonia_store_core::derivation::DerivationOutput;
    use harmonia_store_core::store_path::StoreDir;

    use crate::drv::parse_drv;

    /// Fake but valid 32-char nix base32 hash for test store paths.
    const HASH: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    fn fake_drv_path(name: &str) -> crate::StorePath {
        crate::parse_store_path(&format!("{HASH}-{name}.drv"))
    }

    /// Minimal CA fixed-output derivation (fetchurl-style).
    #[test]
    fn ca_fixed() {
        let store_dir = StoreDir::default();
        let drv_path = fake_drv_path("test-src");
        let drv = parse_drv(
            &store_dir,
            &drv_path,
            &format!(
                r#"Derive([("out","/nix/store/{HASH}-test-src","sha256","deadbeef00000000000000000000000000000000000000000000000000000000")],[],[],"{0}","{0}",[],[("name","test-src")])"#,
                "/bin/sh",
            ),
        )
        .unwrap();

        let (_, output) = drv.outputs.iter().next().unwrap();
        assert!(matches!(output, DerivationOutput::CAFixed(_)));
    }

    /// Minimal input-addressed derivation with two outputs.
    #[test]
    fn input_addressed() {
        let store_dir = StoreDir::default();
        let drv_path = fake_drv_path("hello-1.0");
        let drv = parse_drv(
            &store_dir,
            &drv_path,
            &format!(
                r#"Derive([("lib","/nix/store/{HASH}-hello-1.0-lib","",""),("out","/nix/store/{HASH}-hello-1.0","","")],[],[],"{0}","{0}",[],[("name","hello-1.0")])"#,
                "x86_64-linux",
            ),
        )
        .unwrap();

        assert_eq!(drv.outputs.len(), 2);
        assert!(
            drv.outputs
                .values()
                .all(|o| matches!(o, DerivationOutput::InputAddressed(_)))
        );
    }
}
