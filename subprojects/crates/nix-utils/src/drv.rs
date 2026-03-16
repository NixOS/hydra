use hashbrown::HashMap;
use smallvec::SmallVec;

use crate::BaseStore as _;
use crate::StorePath;

#[derive(Debug, Clone)]
pub struct Output {
    pub name: String,
    pub path: Option<StorePath>,
    pub hash: Option<String>,
    pub hash_algo: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CAOutput {
    pub name: String,
    pub path: StorePath,
    pub hash: String,
    pub hash_algo: String,
}

impl CAOutput {
    pub fn get_sri_hash(&self) -> Result<String, super::Error> {
        let algo = self.hash_algo.strip_prefix("r:").unwrap_or(&self.hash_algo);
        Ok(super::convert_hash(
            &self.hash,
            Some(algo.parse()?),
            super::HashFormat::SRI,
        )?)
    }
}

#[derive(Debug, Clone)]
pub struct DerivationEnv {
    inner: HashMap<String, String>,
}

impl DerivationEnv {
    #[must_use]
    pub const fn new(v: HashMap<String, String>) -> Self {
        Self { inner: v }
    }

    #[must_use]
    pub fn get(&self, k: &str) -> Option<&str> {
        self.inner
            .get(k)
            .and_then(|v| if v.is_empty() { None } else { Some(v.as_str()) })
    }

    #[must_use]
    pub fn get_name(&self) -> Option<&str> {
        self.get("name")
    }

    #[must_use]
    pub fn get_required_system_features(&self) -> Vec<&str> {
        self.get("requiredSystemFeatures")
            .unwrap_or_default()
            .split(' ')
            .filter(|v| !v.is_empty())
            .collect()
    }

    #[must_use]
    pub fn get_output_hash(&self) -> Option<&str> {
        self.get("outputHash")
    }

    #[must_use]
    pub fn get_output_hash_algo(&self) -> Option<&str> {
        self.get("outputHashAlgo")
    }

    #[must_use]
    pub fn get_output_hash_mode(&self) -> Option<&str> {
        self.get("outputHashMode")
    }
}

#[derive(Debug, Clone)]
pub struct Derivation {
    pub env: DerivationEnv,
    pub input_drvs: SmallVec<[String; 8]>,
    pub outputs: SmallVec<[Output; 6]>,
    pub name: StorePath,
    pub system: String,
}

impl Derivation {
    fn new(path: &StorePath, v: nix_diff::types::Derivation) -> Self {
        Self {
            env: DerivationEnv::new(
                v.env
                    .into_iter()
                    .filter_map(|(k, v)| {
                        Some((String::from_utf8(k).ok()?, String::from_utf8(v).ok()?))
                    })
                    .collect(),
            ),
            input_drvs: v
                .input_derivations
                .into_keys()
                .filter_map(|v| String::from_utf8(v).ok())
                .collect(),
            outputs: v
                .outputs
                .into_iter()
                .filter_map(|(k, v)| {
                    Some(Output {
                        name: String::from_utf8(k).ok()?,
                        path: if v.path.is_empty() {
                            None
                        } else {
                            String::from_utf8(v.path).ok().map(|p| StorePath::new(&p))
                        },
                        hash: v
                            .hash
                            .map(String::from_utf8)
                            .transpose()
                            .ok()?
                            .and_then(|v| if v.is_empty() { None } else { Some(v) }),
                        hash_algo: v
                            .hash_algorithm
                            .map(String::from_utf8)
                            .transpose()
                            .ok()?
                            .and_then(|v| if v.is_empty() { None } else { Some(v) }),
                    })
                })
                .collect(),
            name: path.clone(),
            system: String::from_utf8(v.platform).unwrap_or_default(),
        }
    }

    #[must_use]
    pub fn is_ca(&self) -> bool {
        self.outputs
            .iter()
            .any(|o| o.hash.is_some() && o.hash_algo.is_some())
    }

    #[must_use]
    pub fn get_ca_output(&self) -> Option<CAOutput> {
        self.outputs.iter().find_map(|o| {
            Some(CAOutput {
                path: o.path.clone()?,
                hash: o.hash.clone()?,
                hash_algo: o.hash_algo.clone()?,
                name: o.name.clone(),
            })
        })
    }
}

fn parse_drv(drv_path: &StorePath, input: &str) -> Result<Derivation, crate::Error> {
    Ok(Derivation::new(
        drv_path,
        nix_diff::parser::parse_derivation_string(input)?,
    ))
}

#[tracing::instrument(skip(store), fields(%drv), err)]
pub async fn query_drv(
    store: &crate::LocalStore,
    drv: &StorePath,
) -> Result<Option<Derivation>, crate::Error> {
    if !drv.is_drv() {
        return Ok(None);
    }

    let full_path = store.print_store_path(drv);
    if !fs_err::tokio::try_exists(&full_path).await? {
        return Ok(None);
    }

    let input = fs_err::tokio::read_to_string(&full_path).await?;
    Ok(Some(parse_drv(drv, &input)?))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use crate::{StorePath, drv::parse_drv};

    #[test]
    fn test_ca_derivation() {
        let drv_str = r#"Derive([("out","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-linux-6.16.tar.xz","sha256","1a4be2fe6b5246aa4ac8987a8a4af34c42a8dd7d08b46ab48516bcc1befbcd83")],[],[],"builtin","builtin:fetchurl",[],[("builder","builtin:fetchurl"),("executable",""),("impureEnvVars","http_proxy https_proxy ftp_proxy all_proxy no_proxy"),("name","linux-6.16.tar.xz"),("out","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-linux-6.16.tar.xz"),("outputHash","sha256-Gkvi/mtSRqpKyJh6ikrzTEKo3X0ItGq0hRa8wb77zYM="),("outputHashAlgo",""),("outputHashMode","flat"),("preferLocalBuild","1"),("system","builtin"),("unpack",""),("url","https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.16.tar.xz"),("urls","https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.16.tar.xz")])"#;
        let drv_path = StorePath::new("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-linux-6.16.tar.xz.drv");
        let drv = parse_drv(&drv_path, drv_str).unwrap();
        assert_eq!(drv.name, drv_path);
        assert_eq!(drv.env.get_name(), Some("linux-6.16.tar.xz"));
        assert_eq!(
            drv.env.get_output_hash(),
            Some("sha256-Gkvi/mtSRqpKyJh6ikrzTEKo3X0ItGq0hRa8wb77zYM=")
        );
        assert_eq!(drv.env.get_output_hash_algo(), None);
        assert_eq!(drv.env.get_output_hash_mode(), Some("flat"));
        assert!(drv.is_ca());
        let o = drv.get_ca_output().unwrap();
        assert_eq!(
            o.path,
            StorePath::new("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-linux-6.16.tar.xz")
        );
        assert_eq!(o.name, String::from("out"));
        assert_eq!(
            o.hash,
            String::from("1a4be2fe6b5246aa4ac8987a8a4af34c42a8dd7d08b46ab48516bcc1befbcd83")
        );
        assert_eq!(o.hash_algo, String::from("sha256"));
    }

    #[test]
    fn test_no_ca_derivation() {
        let drv_str = r#"Derive([("info","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-gnused-4.9-info","",""),("out","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-gnused-4.9","","")],[("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaawbootstrap-tools.drv",["out"]),("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bootstrap-stage4-stdenv-linux.drv",["out"]),("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-update-autotools-gnu-config-scripts-hook.drv",["out"]),("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-perl-5.40.0.drv",["out"]),("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-sed-4.9.tar.xz.drv",["out"])],["/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source-stdenv.sh","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-default-builder.sh"],"x86_64-linux","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bootstrap-tools/bin/bash",["-e","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-source-stdenv.sh","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-default-builder.sh"],[("NIX_MAIN_PROGRAM","sed"),("__structuredAttrs",""),("buildInputs",""),("builder","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bootstrap-tools/bin/bash"),("cmakeFlags",""),("configureFlags",""),("depsBuildBuild",""),("depsBuildBuildPropagated",""),("depsBuildTarget",""),("depsBuildTargetPropagated",""),("depsHostHost",""),("depsHostHostPropagated",""),("depsTargetTarget",""),("depsTargetTargetPropagated",""),("doCheck",""),("doInstallCheck",""),("info","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-gnused-4.9-info"),("mesonFlags",""),("name","gnused-4.9"),("nativeBuildInputs","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-update-autotools-gnu-config-scripts-hook /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-perl-5.40.0"),("out","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-gnused-4.9"),("outputs","out info"),("patches",""),("pname","gnused"),("preConfigure","patchShebangs ./build-aux/help2man"),("propagatedBuildInputs",""),("propagatedNativeBuildInputs",""),("src","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-sed-4.9.tar.xz"),("stdenv","/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bootstrap-stage4-stdenv-linux"),("strictDeps",""),("system","x86_64-linux"),("version","4.9")])"#;
        let drv_path = StorePath::new("/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-gnused-4.9.drv");
        let drv = parse_drv(&drv_path, drv_str).unwrap();
        assert_eq!(drv.name, drv_path);
        assert!(!drv.is_ca());
    }
}
