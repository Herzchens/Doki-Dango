mod lifecycle;
mod log;

use lifecycle::{HostApp, LaunchOutcome};

fn main() {
    if let Err(error) = run() {
        eprintln!("Doki-Dango Host failed: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    match HostApp::launch()? {
        LaunchOutcome::Primary(app) => app.run(),
        LaunchOutcome::AlreadyRunning => Ok(()),
    }
}
