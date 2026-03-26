use std::collections::HashMap;

use anyhow::{Context as _, bail};
use sqlx::postgres::PgConnectOptions;

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

        let contents = match std::fs::read_to_string(&path) {
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
        self.options
            .get(key)
            .and_then(|v| v.parse().ok())
            .unwrap_or(default)
    }
}

/// Parse a `HYDRA_DBI` environment variable into `PgConnectOptions`.
///
/// Accepts strings like `dbi:Pg:dbname=hydra;host=localhost;port=5432`.
pub(crate) fn parse_hydra_dbi() -> anyhow::Result<PgConnectOptions> {
    let dbi = std::env::var("HYDRA_DBI").unwrap_or_else(|_| "dbi:Pg:dbname=hydra;".to_owned());
    parse_dbi(&dbi)
}

fn parse_dbi(dbi: &str) -> anyhow::Result<PgConnectOptions> {
    let params = dbi
        .strip_prefix("dbi:Pg:")
        .or_else(|| dbi.strip_prefix("DBI:Pg:"))
        .context("$HYDRA_DBI does not denote a PostgreSQL database")?;

    let mut opts = PgConnectOptions::new();

    for pair in params.split(';').filter(|s| !s.is_empty()) {
        let (key, value) = pair
            .split_once('=')
            .with_context(|| format!("invalid DBI parameter: {pair}"))?;
        match key.trim() {
            "dbname" => opts = opts.database(value.trim()),
            "host" => opts = opts.host(value.trim()),
            "port" => {
                opts = opts.port(
                    value
                        .trim()
                        .parse()
                        .with_context(|| format!("invalid port: {value}"))?,
                );
            }
            "user" => opts = opts.username(value.trim()),
            "password" => opts = opts.password(value.trim()),
            "application_name" => opts = opts.application_name(value.trim()),
            other => {
                bail!("unknown DBI parameter: {other}");
            }
        }
    }

    Ok(opts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_simple_dbi() {
        parse_dbi("dbi:Pg:dbname=hydra;host=localhost;port=5432").unwrap();
    }

    #[test]
    fn parse_dbi_uppercase() {
        parse_dbi("DBI:Pg:dbname=testdb;").unwrap();
    }
}
