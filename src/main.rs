//! Thin binary shell. Everything it does is: initialize tracing, call into the
//! library, and map the result to an exit code.
//!
//! Logic does not live here. `main.rs` is the one place allowed to call
//! `std::process::exit` (the `clippy::exit` lint denies it everywhere else),
//! which is exactly why it should be too small to hold a bug.

use std::process::ExitCode;

use tracing_subscriber::EnvFilter;

fn main() -> ExitCode {
    // Tracing comes up before anything else so that even early failures land
    // somewhere. `RUST_LOG` controls the filter; default to `info`.
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    match rust_toolkit_template::run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            // Both channels on purpose: the structured record is for whatever
            // is scraping logs, the `{err:#}` line is for the human staring at
            // a terminal. `{err:?}` would print Rust type paths at them.
            tracing::error!(error = ?err, "fatal error");
            eprintln!("error: {err:#}");
            ExitCode::FAILURE
        }
    }
}
