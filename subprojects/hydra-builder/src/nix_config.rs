//! Read nix configuration by shelling out to `nix show-config --json`.

use std::collections::HashMap;

/// Cached nix configuration values.
#[derive(Debug, Clone)]
pub struct NixConfig {
    values: HashMap<String, serde_json::Value>,
}

impl NixConfig {
    /// Read nix configuration by running `nix show-config --json`.
    pub fn load() -> anyhow::Result<Self> {
        let output = std::process::Command::new("nix")
            .args([
                "--extra-experimental-features",
                "nix-command",
                "show-config",
                "--json",
            ])
            .output()?;
        if !output.status.success() {
            anyhow::bail!(
                "nix show-config failed: {}",
                str::from_utf8(&output.stderr).unwrap_or("Invalid UTF-8")
            );
        }
        let values: HashMap<String, serde_json::Value> = serde_json::from_slice(&output.stdout)?;
        Ok(Self { values })
    }

    fn get_string(&self, key: &str) -> Option<String> {
        self.values
            .get(key)?
            .get("value")?
            .as_str()
            .map(String::from)
    }

    fn get_string_list(&self, key: &str) -> Vec<String> {
        self.values
            .get(key)
            .and_then(|v| v.get("value"))
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn get_bool(&self, key: &str) -> bool {
        self.values
            .get(key)
            .and_then(|v| v.get("value"))
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false)
    }

    #[must_use]
    pub fn system(&self) -> String {
        self.get_string("system")
            .unwrap_or_else(|| std::env::consts::ARCH.to_owned() + "-linux")
    }

    #[must_use]
    pub fn extra_platforms(&self) -> Vec<String> {
        self.get_string_list("extra-platforms")
    }

    #[must_use]
    pub fn system_features(&self) -> Vec<String> {
        self.get_string_list("system-features")
    }

    #[must_use]
    pub fn substituters(&self) -> Vec<String> {
        self.get_string_list("substituters")
    }

    #[must_use]
    pub fn use_cgroups(&self) -> bool {
        self.get_bool("use-cgroups")
    }

    #[must_use]
    pub fn build_dir(&self) -> String {
        self.get_string("build-dir")
            .unwrap_or_else(|| "/tmp".to_owned())
    }

    #[must_use]
    #[allow(clippy::unused_self)]
    pub fn nix_version(&self) -> String {
        std::process::Command::new("nix")
            .arg("--version")
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_owned())
            .unwrap_or_default()
    }
}
