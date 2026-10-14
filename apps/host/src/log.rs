use doki_dango_platform_windows::notifications::{NotificationEvent, NotificationSnapshot};
use std::{
    env,
    fs::{File, OpenOptions, create_dir_all},
    io::{self, Write},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{SystemTime, UNIX_EPOCH},
};

const SYNTHETIC_MARKER: &str = "DOKI-WIN-";

pub struct HostLog {
    file: File,
    path: PathBuf,
}

impl HostLog {
    pub fn new() -> io::Result<Self> {
        let local_app_data = env::var_os("LOCALAPPDATA")
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "LOCALAPPDATA is not set"))?;
        let root = PathBuf::from(local_app_data)
            .join("Doki-Dango")
            .join("Host")
            .join("logs");
        create_dir_all(&root)?;

        let path = root.join(format!("dokidango-{}.log", unix_ms()));
        let file = OpenOptions::new()
            .create_new(true)
            .append(true)
            .open(&path)?;

        Ok(Self { file, path })
    }

    pub fn path(&self) -> &PathBuf {
        &self.path
    }

    pub fn write(&mut self, line: &str) -> io::Result<()> {
        writeln!(self.file, "timestamp_unix_ms={} {line}", unix_ms())?;
        self.file.flush()
    }
}

pub fn write_event(log: &mut HostLog, event: &NotificationEvent) -> io::Result<()> {
    log.write(&format!(
        "operation=notification_event kind={} id={}",
        event.kind.as_str(),
        event.id
    ))?;

    if let Some(snapshot) = &event.snapshot {
        write_snapshot(log, "event_snapshot", snapshot)?;
    }

    Ok(())
}

pub fn write_snapshot(
    log: &mut HostLog,
    operation: &str,
    snapshot: &NotificationSnapshot,
) -> io::Result<()> {
    let synthetic_marker = snapshot
        .text_elements
        .iter()
        .any(|value| value.contains(SYNTHETIC_MARKER));

    let app_display_name = if synthetic_marker {
        sanitize(&snapshot.app_display_name)
    } else {
        "<redacted>".to_string()
    };

    log.write(&format!(
        "operation={operation} id={} app=\"{}\" creation_unix_ms={} text_available={} text_count={} synthetic_marker={}",
        snapshot.id,
        app_display_name,
        snapshot.creation_time_unix_ms,
        snapshot.text_available,
        snapshot.text_elements.len(),
        synthetic_marker
    ))
}

pub fn lock_log(log: &Arc<Mutex<HostLog>>) -> std::sync::MutexGuard<'_, HostLog> {
    log.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

pub fn sanitize(value: &str) -> String {
    value
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace(['\r', '\n', '\t'], " ")
}

pub fn unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}
