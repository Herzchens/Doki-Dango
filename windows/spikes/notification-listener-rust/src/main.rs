use serde_json::{Value, json};
use std::{
    env,
    fs::{OpenOptions, create_dir_all},
    io::{self, Write},
    path::{Path, PathBuf},
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};
use windows::{
    ApplicationModel::Package,
    Foundation::TypedEventHandler,
    UI::Notifications::Management::{
        UserNotificationListener, UserNotificationListenerAccessStatus,
    },
    UI::Notifications::{
        KnownNotificationBindings, NotificationKinds, UserNotification,
        UserNotificationChangedEventArgs, UserNotificationChangedKind,
    },
    Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx, CoUninitialize},
};

const MARKER: &str = "DOKI-NOTIFICATION-";
const WINDOWS_TO_UNIX_EPOCH_TICKS: i64 = 116_444_736_000_000_000;
const TICKS_PER_MILLISECOND: i64 = 10_000;

struct ComApartment;

impl Drop for ComApartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}

#[derive(Clone)]
struct EvidenceWriter {
    path: Arc<PathBuf>,
}

impl EvidenceWriter {
    fn new() -> io::Result<Self> {
        let local_app_data = env::var_os("LOCALAPPDATA")
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "LOCALAPPDATA is not set"))?;
        let root = PathBuf::from(local_app_data)
            .join("Doki-Dango")
            .join("NotificationListenerRust")
            .join("evidence");
        create_dir_all(&root)?;

        let path = root.join(format!("notification-listener-rust-{}.jsonl", unix_ms()));
        Ok(Self {
            path: Arc::new(path),
        })
    }

    fn path(&self) -> &Path {
        self.path.as_ref().as_path()
    }

    fn write(&self, operation: &str, outcome: &str, data: Value) {
        let record = json!({
            "timestampUnixMs": unix_ms(),
            "phase": "notification_listener_rust",
            "operation": operation,
            "outcome": outcome,
            "data": data,
        });

        match OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.path())
        {
            Ok(mut file) => {
                if let Err(error) = writeln!(file, "{record}") {
                    eprintln!("evidence write failed: {error}");
                }
            }
            Err(error) => eprintln!("evidence open failed: {error}"),
        }
    }

    fn write_error(&self, operation: &str, error: &windows::core::Error, data: Value) {
        self.write(
            operation,
            "exception",
            json!({
                "context": data,
                "hresult": format!("{:?}", error.code()),
                "message": error.message(),
            }),
        );
    }
}

fn unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn access_name(status: UserNotificationListenerAccessStatus) -> &'static str {
    if status == UserNotificationListenerAccessStatus::Allowed {
        "Allowed"
    } else if status == UserNotificationListenerAccessStatus::Denied {
        "Denied"
    } else if status == UserNotificationListenerAccessStatus::Unspecified {
        "Unspecified"
    } else {
        "Unknown"
    }
}

fn change_name(kind: UserNotificationChangedKind) -> &'static str {
    if kind == UserNotificationChangedKind::Added {
        "Added"
    } else if kind == UserNotificationChangedKind::Removed {
        "Removed"
    } else {
        "Unknown"
    }
}

fn is_allowed_source(source: &str) -> bool {
    source.eq_ignore_ascii_case("Brave") || source.eq_ignore_ascii_case("Google Chrome")
}

fn creation_unix_ms(notification: &UserNotification) -> windows::core::Result<i64> {
    let ticks = notification.CreationTime()?.UniversalTime;
    Ok((ticks - WINDOWS_TO_UNIX_EPOCH_TICKS) / TICKS_PER_MILLISECOND)
}

fn summarize(notification: &UserNotification) -> windows::core::Result<Value> {
    let app_display_name = notification
        .AppInfo()
        .and_then(|app| app.DisplayInfo())
        .and_then(|display| display.DisplayName())
        .map(|name| name.to_string_lossy())
        .unwrap_or_else(|_| "<unavailable>".to_string());

    let id = notification.Id()?;
    let creation_time_unix_ms = creation_unix_ms(notification)?;

    if !is_allowed_source(&app_display_name) {
        return Ok(json!({
            "appDisplayName": app_display_name,
            "id": id,
            "creationTimeUnixMs": creation_time_unix_ms,
            "textInspection": "not_requested",
        }));
    }

    let text_result: windows::core::Result<Vec<String>> = (|| {
        let binding_name = KnownNotificationBindings::ToastGeneric()?;
        let binding = notification
            .Notification()?
            .Visual()?
            .GetBinding(&binding_name)?;
        let elements = binding.GetTextElements()?;
        let size = elements.Size()?;
        let mut values = Vec::with_capacity(size as usize);

        for index in 0..size {
            values.push(elements.GetAt(index)?.Text()?.to_string_lossy());
        }

        Ok(values)
    })();

    match text_result {
        Ok(text_elements) => {
            let marker_matched = text_elements.iter().any(|text| text.contains(MARKER));
            let title = marker_matched
                .then(|| text_elements.first().cloned())
                .flatten();
            let body = marker_matched.then(|| {
                text_elements
                    .iter()
                    .skip(1)
                    .cloned()
                    .collect::<Vec<_>>()
                    .join("\n")
            });

            Ok(json!({
                "appDisplayName": app_display_name,
                "id": id,
                "creationTimeUnixMs": creation_time_unix_ms,
                "textInspection": "allowed_source",
                "textElementCount": text_elements.len(),
                "markerMatched": marker_matched,
                "title": title,
                "body": body,
            }))
        }
        Err(error) => Ok(json!({
            "appDisplayName": app_display_name,
            "id": id,
            "creationTimeUnixMs": creation_time_unix_ms,
            "textInspection": "exception",
            "hresult": format!("{:?}", error.code()),
            "message": error.message(),
        })),
    }
}

fn poll(
    listener: &UserNotificationListener,
    evidence: &EvidenceWriter,
) -> windows::core::Result<()> {
    let started = unix_ms();
    let notifications = listener
        .GetNotificationsAsync(NotificationKinds::Toast)?
        .join()?;
    let finished = unix_ms();
    let size = notifications.Size()?;

    evidence.write(
        "GetNotificationsAsync",
        "success",
        json!({
            "count": size,
            "startedUnixMs": started,
            "finishedUnixMs": finished,
            "elapsedMs": finished.saturating_sub(started),
        }),
    );

    for index in 0..size {
        let notification = notifications.GetAt(index)?;
        match summarize(&notification) {
            Ok(snapshot) => evidence.write("notification_snapshot", "observed", snapshot),
            Err(error) => {
                evidence.write_error("notification_snapshot", &error, json!({ "index": index }))
            }
        }
    }

    Ok(())
}

fn handle_event(
    sender: &UserNotificationListener,
    args: &UserNotificationChangedEventArgs,
    evidence: &EvidenceWriter,
) {
    let event_result: windows::core::Result<()> = (|| {
        let kind = args.ChangeKind()?;
        let id = args.UserNotificationId()?;

        evidence.write(
            "NotificationChanged.event",
            "observed",
            json!({
                "changeKind": change_name(kind),
                "userNotificationId": id,
            }),
        );

        if kind == UserNotificationChangedKind::Added {
            match sender.GetNotification(id) {
                Ok(notification) => match summarize(&notification) {
                    Ok(snapshot) => {
                        evidence.write("notification_event_snapshot", "observed", snapshot)
                    }
                    Err(error) => evidence.write_error(
                        "notification_event_snapshot",
                        &error,
                        json!({ "userNotificationId": id }),
                    ),
                },
                Err(error) => evidence.write_error(
                    "notification_event_snapshot",
                    &error,
                    json!({ "userNotificationId": id }),
                ),
            }
        }

        Ok(())
    })();

    if let Err(error) = event_result {
        evidence.write_error("NotificationChanged.event", &error, json!({}));
    }
}

fn run() -> windows::core::Result<()> {
    let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
    hr.ok()?;
    let _apartment = ComApartment;
    let evidence = EvidenceWriter::new().map_err(|error| {
        windows::core::Error::new(
            windows::core::HRESULT(0x80004005u32 as i32),
            format!("{error}"),
        )
    })?;

    let package_full_name = Package::Current()?.Id()?.FullName()?.to_string_lossy();

    evidence.write(
        "harness_launch",
        "success",
        json!({
            "packageForm": "packaged",
            "packageFullName": package_full_name,
            "rust": true,
            "windowsCrate": "0.62.2",
        }),
    );

    println!("Doki-Dango Rust notification listener harness");
    println!("Evidence: {}", evidence.path().display());

    let listener = match UserNotificationListener::Current() {
        Ok(listener) => {
            evidence.write("UserNotificationListener.Current", "success", json!({}));
            listener
        }
        Err(error) => {
            evidence.write_error("UserNotificationListener.Current", &error, json!({}));
            return Err(error);
        }
    };

    let before = listener.GetAccessStatus()?;
    evidence.write(
        "GetAccessStatus",
        "success",
        json!({ "status": access_name(before) }),
    );

    let after = if before == UserNotificationListenerAccessStatus::Allowed {
        before
    } else {
        match listener.RequestAccessAsync()?.join() {
            Ok(status) => {
                evidence.write(
                    "RequestAccessAsync",
                    "success",
                    json!({
                        "before": access_name(before),
                        "result": access_name(status),
                        "after": access_name(listener.GetAccessStatus()?),
                    }),
                );
                status
            }
            Err(error) => {
                evidence.write_error(
                    "RequestAccessAsync",
                    &error,
                    json!({ "before": access_name(before) }),
                );
                return Err(error);
            }
        }
    };

    if after != UserNotificationListenerAccessStatus::Allowed {
        evidence.write(
            "listener_ready",
            "blocked",
            json!({ "accessStatus": access_name(after) }),
        );
        return Err(windows::core::Error::new(
            windows::core::HRESULT(0x80070005u32 as i32),
            "notification listener access is not allowed",
        ));
    }

    if let Err(error) = poll(&listener, &evidence) {
        evidence.write_error("GetNotificationsAsync", &error, json!({}));
        return Err(error);
    }

    let event_evidence = evidence.clone();
    let handler =
        TypedEventHandler::<UserNotificationListener, UserNotificationChangedEventArgs>::new(
            move |sender, args| {
                if let (Some(sender), Some(args)) = (sender.as_ref(), args.as_ref()) {
                    handle_event(sender, args, &event_evidence);
                }
                Ok(())
            },
        );

    let token = match listener.NotificationChanged(&handler) {
        Ok(token) => {
            evidence.write(
                "NotificationChanged.subscribe",
                "success",
                json!({ "accessStatus": access_name(listener.GetAccessStatus()?) }),
            );
            token
        }
        Err(error) => {
            evidence.write_error("NotificationChanged.subscribe", &error, json!({}));
            return Err(error);
        }
    };

    evidence.write(
        "listener_ready",
        "success",
        json!({
            "marker": MARKER,
            "allowedSources": ["Brave", "Google Chrome"],
        }),
    );

    println!("Listener ready. Create synthetic notifications in Brave/Chrome.");
    println!("Press Enter to stop after parity observations are complete.");

    let mut input = String::new();
    let _ = io::stdin().read_line(&mut input);

    match listener.RemoveNotificationChanged(token) {
        Ok(()) => evidence.write("NotificationChanged.unsubscribe", "success", json!({})),
        Err(error) => evidence.write_error("NotificationChanged.unsubscribe", &error, json!({})),
    }

    drop(handler);
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!(
            "Rust notification listener harness failed: {:?}: {}",
            error.code(),
            error.message()
        );
        std::process::exit(1);
    }
}
