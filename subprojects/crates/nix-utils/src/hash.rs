use harmonia_utils_hash::fmt::{Any, CommonHash as _};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HashFormat {
    Base64,
    Nix32,
    Base16,
    SRI,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HashAlgorithm {
    MD5,
    SHA1,
    SHA256,
    SHA512,
    BLAKE3,
}

impl From<HashAlgorithm> for harmonia_utils_hash::Algorithm {
    fn from(value: HashAlgorithm) -> Self {
        match value {
            HashAlgorithm::MD5 => Self::MD5,
            HashAlgorithm::SHA1 => Self::SHA1,
            HashAlgorithm::SHA256 => Self::SHA256,
            HashAlgorithm::SHA512 => Self::SHA512,
            HashAlgorithm::BLAKE3 => panic!("BLAKE3 not supported by harmonia"),
        }
    }
}

#[derive(thiserror::Error, Debug)]
pub enum ParseError {
    #[error("Invalid Algorithm passed: {0}")]
    InvalidAlgorithm(String),

    #[error("Hash parse error: {0}")]
    HashParse(String),
}

impl std::str::FromStr for HashAlgorithm {
    type Err = ParseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "md5" => Ok(Self::MD5),
            "sha1" => Ok(Self::SHA1),
            "sha256" => Ok(Self::SHA256),
            "sha512" => Ok(Self::SHA512),
            "blake3" => Ok(Self::BLAKE3),
            _ => Err(ParseError::InvalidAlgorithm(s.into())),
        }
    }
}

/// Convert a hash string from one format to another.
///
/// When `algo` is [`Some`], the input string is parsed as a bare hash in that algorithm.
/// When `algo` is [`None`], the input must include the algorithm prefix (e.g. `sha256:...`).
pub fn convert_hash(
    s: &str,
    algo: Option<HashAlgorithm>,
    out_format: HashFormat,
) -> Result<String, ParseError> {
    let hash = if let Some(algo) = algo {
        let algo = harmonia_utils_hash::Algorithm::from(algo);
        // Try parsing as "algo:hash" first, then as bare hash with known algo
        let prefixed = format!("{algo}:{s}");
        prefixed
            .parse::<Any<harmonia_utils_hash::Hash>>()
            .map(Any::into_hash)
            .map_err(|e| ParseError::HashParse(e.to_string()))?
    } else {
        s.parse::<Any<harmonia_utils_hash::Hash>>()
            .map(Any::into_hash)
            .map_err(|e| ParseError::HashParse(e.to_string()))?
    };

    Ok(match out_format {
        HashFormat::Base16 => format!("{}", hash.as_base16()),
        HashFormat::Nix32 => format!("{}", hash.as_base32()),
        HashFormat::Base64 => format!("{}", hash.as_base64()),
        HashFormat::SRI => format!("{}", hash.as_sri()),
    })
}
