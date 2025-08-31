#[cxx::bridge(namespace = "nix_utils::hash")]
mod ffi {
    #![allow(unreachable_pub, unused_qualifications)]

    enum HashFormat {
        Base64,
        Nix32,
        Base16,
        SRI,
    }

    enum OptionalHashAlgorithm {
        None,
        MD5,
        SHA1,
        SHA256,
        SHA512,
        BLAKE3,
    }

    unsafe extern "C++" {
        include!("nix-utils/include/hash.h");

        fn convert_hash(
            s: &str,
            algo: OptionalHashAlgorithm,
            out_format: HashFormat,
        ) -> Result<String>;
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HashFormat {
    Base64,
    Nix32,
    Base16,
    SRI,
}

impl From<HashFormat> for ffi::HashFormat {
    fn from(value: HashFormat) -> Self {
        match value {
            HashFormat::Base64 => Self::Base64,
            HashFormat::Nix32 => Self::Nix32,
            HashFormat::Base16 => Self::Base16,
            HashFormat::SRI => Self::SRI,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HashAlgorithm {
    MD5,
    SHA1,
    SHA256,
    SHA512,
    BLAKE3,
}

impl From<Option<HashAlgorithm>> for ffi::OptionalHashAlgorithm {
    fn from(value: Option<HashAlgorithm>) -> Self {
        value.map_or(Self::None, |v| match v {
            HashAlgorithm::MD5 => Self::MD5,
            HashAlgorithm::SHA1 => Self::SHA1,
            HashAlgorithm::SHA256 => Self::SHA256,
            HashAlgorithm::SHA512 => Self::SHA512,
            HashAlgorithm::BLAKE3 => Self::BLAKE3,
        })
    }
}

#[derive(thiserror::Error, Debug)]
pub enum ParseError {
    #[error("Invalid Algorithm passed: {0}")]
    InvalidAlgorithm(String),
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

#[inline]
pub fn convert_hash(
    s: &str,
    algo: Option<HashAlgorithm>,
    out_format: HashFormat,
) -> Result<String, cxx::Exception> {
    ffi::convert_hash(s, algo.into(), out_format.into())
}
