//! The binary is a thin shell over this library.
//!
//! Keeping the work here rather than in `main.rs` means it can be tested
//! without spawning a process. As the project grows, the shape to hold is:
//! IO-bound and framework-bound code (HTTP handlers, event loops, GUI
//! callbacks) stays in a thin *shell* layer that calls into *pure* modules
//! where the logic lives. The shell is usually not unit-tested; the pure
//! modules always are.

pub mod config;

use anyhow::Context as _;

use crate::config::Settings;

/// Run the application.
///
/// # Errors
///
/// Returns an error if settings cannot be read from the environment.
pub fn run() -> anyhow::Result<()> {
    let settings = Settings::from_process_env().context("failed to load settings")?;

    tracing::info!(log_level = %settings.log_level, "starting");

    Ok(())
}
