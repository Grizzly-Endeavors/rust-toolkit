//! Settings read from the process environment.
//!
//! This module exists mostly to demonstrate two conventions: it is a *pure*
//! module (no IO of its own — the environment arrives as a closure), and its
//! tests live in a sibling file rather than at the bottom of this one.
//!
//! Rust 2024 made `std::env::set_var` and `remove_var` `unsafe`, so tests must
//! not mutate the real environment. Env-reading functions are therefore written
//! as a pair: a zero-arg function that reads the real process environment, and
//! a `_from_env` sibling that takes a lookup closure the tests can supply.

use std::ffi::OsString;

/// A lookup into some environment.
///
/// `std::env::var_os` in production, a fixture closure in tests.
pub type EnvLookup<'a> = dyn Fn(&str) -> Option<OsString> + 'a;

/// Application settings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settings {
    /// Tracing filter directive, e.g. `info` or `myapp=debug`.
    pub log_level: String,
}

impl Settings {
    /// Read settings from the real process environment.
    ///
    /// # Errors
    ///
    /// Returns an error if a recognized variable is set but not valid UTF-8.
    pub fn from_process_env() -> anyhow::Result<Self> {
        Self::from_env(&|key| std::env::var_os(key))
    }

    /// Read settings from an arbitrary environment.
    ///
    /// # Errors
    ///
    /// Returns an error if a recognized variable is set but not valid UTF-8.
    pub fn from_env(get: &EnvLookup<'_>) -> anyhow::Result<Self> {
        let log_level = match get("RUST_LOG") {
            Some(raw) => raw
                .into_string()
                .map_err(|raw| anyhow::anyhow!("RUST_LOG is not valid UTF-8: {}", raw.display()))?,
            None => "info".to_owned(),
        };

        Ok(Self { log_level })
    }
}

#[cfg(test)]
#[path = "tests/config.rs"]
mod tests;
