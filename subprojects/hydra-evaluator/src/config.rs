use std::collections::HashMap;

#[derive(Debug)]
pub(crate) struct HydraConfig {
    options: HashMap<String, String>,
}

impl HydraConfig {
    pub(crate) fn load() -> Self {
        let mut options = HashMap::new();

        let path = match std::env::var("HYDRA_CONFIG") {
            Ok(p) if !p.is_empty() => p,
            _ => return Self { options },
        };

        let contents = match fs_err::read_to_string(&path) {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("could not read HYDRA_CONFIG at {path}: {e}");
                return Self { options };
            }
        };

        for line in contents.lines() {
            // Strip comments
            let line = match line.find('#') {
                Some(pos) => &line[..pos],
                None => line,
            };
            let line = line.trim();

            let Some(eq) = line.find('=') else {
                continue;
            };

            let key = line[..eq].trim();
            let value = line[eq + 1..].trim();

            if key.is_empty() {
                continue;
            }

            options.insert(key.to_owned(), value.to_owned());
        }

        Self { options }
    }

    pub(crate) fn get_int(&self, key: &str, default: u64) -> u64 {
        match self.options.get(key) {
            None => default,
            Some(v) => v.parse().unwrap_or_else(|_| {
                // The C++ evaluator failed loudly on unparsable values;
                // at least warn so a hydra.conf typo is visible.
                tracing::warn!("invalid value for {key} in hydra.conf: {v:?}, using {default}");
                default
            }),
        }
    }
}
