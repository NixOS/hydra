use async_compression::{
    Level,
    tokio::bufread::{
        BrotliDecoder, BrotliEncoder, BzDecoder, BzEncoder, XzDecoder, XzEncoder, ZstdDecoder,
        ZstdEncoder,
    },
};

pub(crate) type CompressorFn<C> =
    Box<dyn FnOnce(C) -> Box<dyn tokio::io::AsyncRead + Unpin + Send> + Send>;

pub(crate) type DecompressorFn<C> =
    Box<dyn FnOnce(C) -> Box<dyn tokio::io::AsyncRead + Unpin + Send> + Send>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Compression {
    None,
    Xz,
    Bzip2,
    Brotli,
    Zstd,
}

impl Compression {
    #[must_use]
    pub const fn ext(self) -> &'static str {
        match self {
            Self::None => "nar",
            Self::Xz => "nar.xz",
            Self::Bzip2 => "nar.bz2",
            Self::Brotli => "nar.br",
            Self::Zstd => "nar.zst",
        }
    }

    #[must_use]
    pub const fn content_type(self) -> &'static str {
        "application/x-nix-nar"
    }

    /// `Content-Encoding` for fixed-name objects (`.ls`, `.narinfo`, logs) whose
    /// name does not encode the compression. NARs must not use this; their
    /// compression is in the `.nar.<ext>` URL and narinfo `Compression:` field.
    #[must_use]
    pub const fn content_encoding(self) -> &'static str {
        match self {
            Self::None => "",
            Self::Xz => "xz",
            Self::Bzip2 => "bzip2",
            Self::Brotli => "br",
            Self::Zstd => "zstd",
        }
    }

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Xz => "xz",
            Self::Bzip2 => "bzip2",
            Self::Brotli => "br",
            Self::Zstd => "zstd",
        }
    }

    #[must_use]
    pub fn get_compression_fn<C: tokio::io::AsyncBufRead + Unpin + Send + 'static>(
        self,
        level: Level,
        parallel: bool,
    ) -> CompressorFn<C> {
        match self {
            Self::None => Box::new(|c| Box::new(c)),
            Self::Xz => {
                if parallel && let Some(cores) = std::num::NonZero::new(4) {
                    Box::new(move |s| Box::new(XzEncoder::parallel(s, level, cores)))
                } else {
                    Box::new(move |s| Box::new(XzEncoder::with_quality(s, level)))
                }
            }
            Self::Bzip2 => Box::new(move |s| Box::new(BzEncoder::with_quality(s, level))),
            Self::Brotli => Box::new(move |s| Box::new(BrotliEncoder::with_quality(s, level))),
            Self::Zstd => Box::new(move |s| Box::new(ZstdEncoder::with_quality(s, level))),
        }
    }

    /// Wrap a compressed byte stream in the matching decoder, yielding the
    /// plaintext NAR bytes. Used when reading NARs back out of the cache.
    #[must_use]
    pub fn get_decompression_fn<C: tokio::io::AsyncBufRead + Unpin + Send + 'static>(
        self,
    ) -> DecompressorFn<C> {
        match self {
            Self::None => Box::new(|c| Box::new(c)),
            Self::Xz => Box::new(|s| Box::new(XzDecoder::new(s))),
            Self::Bzip2 => Box::new(|s| Box::new(BzDecoder::new(s))),
            Self::Brotli => Box::new(|s| Box::new(BrotliDecoder::new(s))),
            Self::Zstd => Box::new(|s| Box::new(ZstdDecoder::new(s))),
        }
    }
}

/// Invalid compression type string.
#[derive(Debug, Clone, thiserror::Error)]
#[error("invalid compression: {got:?} (expected \"none\", \"xz\", \"bzip2\", \"br\", or \"zstd\")")]
pub struct InvalidCompression {
    pub got: String,
}

impl std::str::FromStr for Compression {
    type Err = InvalidCompression;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "none" => Ok(Self::None),
            "xz" => Ok(Self::Xz),
            "bzip2" => Ok(Self::Bzip2),
            "br" => Ok(Self::Brotli),
            "zstd" | "zst" => Ok(Self::Zstd),
            o => Err(InvalidCompression { got: o.to_string() }),
        }
    }
}
