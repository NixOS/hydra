#![deny(clippy::all)]
#![deny(clippy::pedantic)]
#![deny(clippy::unwrap_used)]
#![deny(clippy::expect_used)]
#![allow(clippy::missing_errors_doc)]
#![recursion_limit = "256"]

pub mod config;
pub mod io;
pub mod server;
pub mod state;
pub mod utils;
