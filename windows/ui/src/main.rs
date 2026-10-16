#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::{
    env,
    fs::{File, OpenOptions, create_dir_all},
    io::{self, Write},
    path::PathBuf,
    process,
    time::{SystemTime, UNIX_EPOCH},
};

fn main() {
    if let Err(error) = run() {
        eprintln!("Doki-Dango UI bootstrap failed: {error}");
        process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let executable_path = env::current_exe()?;
    let mut log = UiLog::new()?;

    log.write(&format!(
        "operation=ui_process role=settings_surface status=started pid={} executable_path=\"{}\"",
        process::id(),
        sanitize(&executable_path.display().to_string())
    ))?;
    log.write(
        "operation=ui_process role=settings_surface status=exiting reason=bootstrap_complete exit_code=0",
    )?;

    Ok(())
}

struct UiLog {
    file: File,
}

impl UiLog {
    fn new() -> io::Result<Self> {
        let local_app_data = env::var_os("LOCALAPPDATA")
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "LOCALAPPDATA is not set"))?;
        let root = PathBuf::from(local_app_data)
            .join("Doki-Dango")
            .join("UI")
            .join("logs");
        create_dir_all(&root)?;

        let path = root.join(format!("dokidango-ui-{}.log", unix_ms()));
        let file = OpenOptions::new()
            .create_new(true)
            .append(true)
            .open(path)?;

        Ok(Self { file })
    }

    fn write(&mut self, line: &str) -> io::Result<()> {
        writeln!(self.file, "timestamp_unix_ms={} {line}", unix_ms())?;
        self.file.flush()
    }
}

fn sanitize(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace(['\r', '\n', '\t'], " ")
}

fn unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}
