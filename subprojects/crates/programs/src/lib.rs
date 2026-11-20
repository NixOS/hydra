//! Where to find the programs Hydra runs.
//!
//! Hydra does not look its programs up on `PATH`. Each one it runs is named
//! by an environment variable of its own, `HYDRA_PROGRAM_<NAME>`: the
//! program's name upper-cased, with `-` as `_`. Whoever starts Hydra -- the
//! NixOS module, a wrapper, the test suite -- sets them, and a missing one is
//! an error at startup, rather than whatever `PATH` happens to turn up.
//!
//! Each program's location has a type of its own, made with [`program!`], so
//! that a signature says which program it wants rather than taking just some
//! path.
//!
//! The Perl side follows the same convention, in `Hydra::Helper::Exec`.

use std::path::PathBuf;

/// A program Hydra needs, whose variable is not set.
#[derive(Debug, thiserror::Error)]
#[error("{var} is not set: it must name the `{program}` program")]
pub struct Missing {
    pub program: &'static str,
    pub var: String,
}

/// The variable that names `program`.
#[must_use]
pub fn var_name(program: &str) -> String {
    format!(
        "HYDRA_PROGRAM_{}",
        program.to_ascii_uppercase().replace('-', "_")
    )
}

/// The location of one particular program. Implemented by [`program!`].
pub trait Program: Sized {
    /// The program's name, which its variable is made from.
    const NAME: &'static str;

    fn from_path(path: PathBuf) -> Self;

    /// Where to find the program, from its variable.
    fn locate() -> Result<Self, Missing> {
        let var = var_name(Self::NAME);
        std::env::var_os(&var)
            .filter(|v| !v.is_empty())
            .map(|v| Self::from_path(PathBuf::from(v)))
            .ok_or(Missing {
                program: Self::NAME,
                var,
            })
    }
}

/// Define the type for one program's location: `program!(pub NixPath, "nix");`.
///
/// It can be handed straight to `Command::new`.
#[macro_export]
macro_rules! program {
    ($(#[$meta:meta])* $vis:vis $ty:ident, $name:literal) => {
        $(#[$meta])*
        #[derive(Debug, Clone)]
        $vis struct $ty(::std::path::PathBuf);

        impl $crate::Program for $ty {
            const NAME: &'static str = $name;

            fn from_path(path: ::std::path::PathBuf) -> Self {
                Self(path)
            }
        }

        impl ::std::convert::AsRef<::std::ffi::OsStr> for $ty {
            fn as_ref(&self) -> &::std::ffi::OsStr {
                self.0.as_os_str()
            }
        }
    };
}

program!(
    /// `nix`, which every Hydra daemon runs for something.
    pub NixPath,
    "nix"
);

#[cfg(test)]
mod tests {
    #[test]
    fn var_name_follows_the_convention() {
        assert_eq!(
            super::var_name("nix-eval-jobs"),
            "HYDRA_PROGRAM_NIX_EVAL_JOBS"
        );
        assert_eq!(
            super::var_name("hydra-fetch-input"),
            "HYDRA_PROGRAM_HYDRA_FETCH_INPUT"
        );
    }
}
