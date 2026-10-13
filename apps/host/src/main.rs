use doki_dango_platform_windows::{
    current_package_full_name, initialize_sta,
    notifications::{
        NotificationAccess, NotificationEvent, NotificationListener, NotificationSnapshot,
    },
};
use std::{
    env,
    fs::{File, OpenOptions, create_dir_all},
    io::{self, Write},
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

const SYNTHETIC_MARKER: &str = "DOKI-WIN-";

struct HostLog {
    file: File,
    path: PathBuf,
}

impl HostLog {
    fn new() -> io::Result<Self> {
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

    fn path(&self) -> &PathBuf {
        &self.path
    }

    fn write(&mut self, line: &str) -> io::Result<()> {
        writeln!(self.file, "timestamp_unix_ms={} {line}", unix_ms())?;
        self.file.flush()
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("Doki-Dango Host failed: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let _apartment = initialize_sta()?;
    let package_full_name = current_package_full_name()?;
    let listener = NotificationListener::current()?;

    let log = Arc::new(Mutex::new(HostLog::new()?));
    {
        let mut log_guard = lock_log(&log);
        log_guard.write(&format!(
            "operation=startup package_full_name=\"{}\" executable=dokidango.exe",
            sanitize(&package_full_name)
        ))?;
    }

    let before = listener.access_status()?;
    let after = if before == NotificationAccess::Allowed {
        before
    } else {
        listener.request_access()?
    };

    {
        let mut log_guard = lock_log(&log);
        log_guard.write(&format!(
            "operation=access before={} after={}",
            before.as_str(),
            after.as_str()
        ))?;
    }

    if after != NotificationAccess::Allowed {
        return Err(format!("notification listener access is {}", after.as_str()).into());
    }

    let snapshots = listener.poll()?;
    {
        let mut log_guard = lock_log(&log);
        log_guard.write(&format!("operation=poll count={}", snapshots.len()))?;
        for snapshot in &snapshots {
            write_snapshot(&mut log_guard, "poll_snapshot", snapshot)?;
        }
    }

    let event_log = Arc::clone(&log);
    let _subscription = listener.subscribe(move |event| {
        let mut log_guard = lock_log(&event_log);
        if let Err(error) = write_event(&mut log_guard, &event) {
            eprintln!("Doki-Dango Host event log failed: {error}");
        }
    })?;

    {
        let mut log_guard = lock_log(&log);
        log_guard.write("operation=listener_ready status=success")?;
        println!("Doki-Dango Host listener ready.");
        println!("Log: {}", log_guard.path().display());
    }

    loop {
        thread::sleep(Duration::from_secs(3600));
    }
}

fn write_event(log: &mut HostLog, event: &NotificationEvent) -> io::Result<()> {
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

fn write_snapshot(
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

fn lock_log(log: &Arc<Mutex<HostLog>>) -> std::sync::MutexGuard<'_, HostLog> {
    log.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
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
