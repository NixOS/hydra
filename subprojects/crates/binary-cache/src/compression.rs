use async_compression::{
    Level,
    tokio::bufread::{BrotliEncoder, BzEncoder, XzEncoder, ZstdEncoder},
};

pub(crate) type CompressorFn<C> =
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

    #[must_use]
    pub const fn content_encoding(self) -> &'static str {
        ""
    }

    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Xz => "xz",
            Self::Bzip2 => "bz2",
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
}

impl std::str::FromStr for Compression {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s.trim().to_ascii_lowercase().as_str() {
            "none" => Ok(Self::None),
            "xz" => Ok(Self::Xz),
            "bz2" => Ok(Self::Bzip2),
            "br" => Ok(Self::Brotli),
            "zstd" | "zst" => Ok(Self::Zstd),
            o => Err(o.to_string()),
        }
    }
}
