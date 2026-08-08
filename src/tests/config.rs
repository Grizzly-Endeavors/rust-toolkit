//! Tests for [`super`].
//!
//! Loaded by `src/config.rs` via `#[path = "tests/config.rs"] mod tests;`, which
//! makes this a *child* of that module — so `use super::*` reaches private items
//! exactly as an inline `mod tests` would. No visibility inflation, no test
//! noise in the impl file.
//!
//! Note there is no `#[expect(clippy::unwrap_used, ...)]` header here. The root
//! `clippy.toml` already exempts unwrap in tests, so an expectation would never
//! fire and would itself become an unfulfilled-expectation error.

use std::ffi::OsString;

use super::Settings;

/// Build a lookup closure over a fixed set of pairs.
fn env_with(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
    let owned: Vec<(String, String)> = pairs
        .iter()
        .map(|&(key, value)| (key.to_owned(), value.to_owned()))
        .collect();

    move |key| {
        owned
            .iter()
            .find(|(candidate, _)| candidate == key)
            .map(|(_, value)| OsString::from(value))
    }
}

#[test]
fn log_level_defaults_to_info_when_unset() {
    let settings = Settings::from_env(&env_with(&[])).unwrap();

    assert_eq!(
        settings.log_level, "info",
        "an unset RUST_LOG should fall back to info"
    );
}

#[test]
fn log_level_is_read_from_the_environment() {
    let settings = Settings::from_env(&env_with(&[("RUST_LOG", "myapp=debug")])).unwrap();

    assert_eq!(
        settings.log_level, "myapp=debug",
        "RUST_LOG should override the default"
    );
}

#[test]
fn non_utf8_log_level_is_an_error() {
    let result = Settings::from_env(&|_| Some(invalid_utf8()));

    assert!(
        result.is_err(),
        "a RUST_LOG that is not valid UTF-8 should be reported, not silently dropped"
    );
}

/// An `OsString` that cannot be converted to a `String`.
#[cfg(unix)]
fn invalid_utf8() -> OsString {
    use std::os::unix::ffi::OsStringExt as _;

    OsString::from_vec(vec![0xff, 0xfe])
}

#[cfg(not(unix))]
fn invalid_utf8() -> OsString {
    use std::os::windows::ffi::OsStringExt as _;

    OsString::from_wide(&[0xd800])
}
