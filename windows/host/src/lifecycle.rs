use crate::log::{HostLog, lock_log, sanitize};
use doki_dango_host::diagnostics::{AccessState, DiagnosticEvent, Diagnostics};
use doki_dango_platform_windows::{
    ComApartment, HOST_STARTUP_TASK_ID, InstanceAcquisition, SingleInstanceGuard,
    acquire_host_instance, current_package_full_name, host_startup_task_state,
    host_ui_ipc::{HOST_UI_IPC_VERSION, HostUiIpcServer},
    initialize_sta,
    notifications::{NotificationAccess, NotificationListener, NotificationSubscription},
};
use std::{
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

pub struct HostApp {
    _apartment: ComApartment,
    _instance: SingleInstanceGuard,
    _subscription: NotificationSubscription,
    _log: Arc<Mutex<HostLog>>,
    _diagnostics: Option<Diagnostics>,
}

pub enum LaunchOutcome {
    Primary(HostApp),
    AlreadyRunning,
}

impl HostApp {
    pub fn launch() -> Result<LaunchOutcome, Box<dyn std::error::Error>> {
        let instance = match acquire_host_instance()? {
            InstanceAcquisition::Primary(guard) => guard,
            InstanceAcquisition::AlreadyRunning => {
                let mut log = HostLog::new()?;
                log.write("operation=lifecycle status=already_running")?;
                println!("Doki-Dango Host is already running in this user session.");
                return Ok(LaunchOutcome::AlreadyRunning);
            }
        };

        // Diagnostics are best-effort and must never block listener startup.
        let mut diagnostics = Diagnostics::open_default().ok();
        if let Some(recorder) = diagnostics.as_mut() {
            let _ = recorder.record(DiagnosticEvent::HostStarting);
        }

        let log = Arc::new(Mutex::new(HostLog::new()?));
        {
            let mut log_guard = lock_log(&log);
            log_guard.write("operation=lifecycle status=starting")?;
        }

        let apartment = initialize_sta()?;
        let package_full_name = current_package_full_name()?;

        {
            let mut log_guard = lock_log(&log);
            log_guard.write(&format!(
                "operation=startup package_full_name=\"{}\" executable=dokidango.exe",
                sanitize(&package_full_name)
            ))?;
        }

        let startup_state = host_startup_task_state();
        {
            let mut log_guard = lock_log(&log);
            match startup_state {
                Ok(state) => log_guard.write(&format!(
                    "operation=startup_task task_id=\"{}\" state={}",
                    HOST_STARTUP_TASK_ID,
                    state.as_str()
                ))?,
                Err(error) => log_guard.write(&format!(
                    "operation=startup_task task_id=\"{}\" state=Unavailable hresult=0x{:08X}",
                    HOST_STARTUP_TASK_ID,
                    error.code().0 as u32
                ))?,
            }
        }

        let listener = NotificationListener::current()?;
        let before = listener.access_status()?;
        let after = if before == NotificationAccess::Allowed {
            before
        } else {
            listener.request_access()?
        };

        if let Some(recorder) = diagnostics.as_mut() {
            let _ = recorder.record(DiagnosticEvent::ListenerAccess {
                status: AccessState::from(after),
            });
        }

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
        if let Some(recorder) = diagnostics.as_mut() {
            let _ = recorder.record(DiagnosticEvent::ListenerPoll {
                count: u64::try_from(snapshots.len()).unwrap_or(u64::MAX),
            });
        }
        {
            let mut log_guard = lock_log(&log);
            log_guard.write(&format!("operation=poll count={}", snapshots.len()))?;
            for snapshot in &snapshots {
                crate::log::write_snapshot(&mut log_guard, "poll_snapshot", snapshot)?;
            }
        }

        let event_log = Arc::clone(&log);
        let subscription = listener.subscribe(move |event| {
            let mut log_guard = lock_log(&event_log);
            if let Err(error) = crate::log::write_event(&mut log_guard, &event) {
                eprintln!("Doki-Dango Host event log failed: {error}");
            }
        })?;

        if let Some(recorder) = diagnostics.as_mut() {
            let _ = recorder.record(DiagnosticEvent::ListenerReady);
        }
        {
            let mut log_guard = lock_log(&log);
            log_guard.write("operation=listener_ready status=success")?;
            log_guard.write("operation=lifecycle status=running")?;
            println!("Doki-Dango Host listener ready.");
            println!("Log: {}", log_guard.path().display());
        }

        start_host_ui_ipc(Arc::clone(&log));

        Ok(LaunchOutcome::Primary(HostApp {
            _apartment: apartment,
            _instance: instance,
            _subscription: subscription,
            _log: log,
            _diagnostics: diagnostics,
        }))
    }

    pub fn run(&self) -> Result<(), Box<dyn std::error::Error>> {
        loop {
            thread::sleep(Duration::from_secs(3600));
        }
    }
}

fn start_host_ui_ipc(log: Arc<Mutex<HostLog>>) {
    let thread_log = Arc::clone(&log);
    let spawn_result = thread::Builder::new()
        .name("doki-host-ui-ipc".to_string())
        .spawn(move || match HostUiIpcServer::bind_default() {
            Ok(server) => {
                {
                    let mut log_guard = lock_log(&thread_log);
                    let _ = log_guard.write(&format!(
                        "operation=host_ui_ipc status=started ipc_version={HOST_UI_IPC_VERSION}"
                    ));
                }

                loop {
                    if let Err(error) = server.serve_once() {
                        let mut log_guard = lock_log(&thread_log);
                        let _ = log_guard.write(&format!(
                            "operation=host_ui_ipc status=request_failed error_kind={}",
                            error.kind().as_str()
                        ));
                    }
                }
            }
            Err(error) => {
                let mut log_guard = lock_log(&thread_log);
                let _ = log_guard.write(&format!(
                    "operation=host_ui_ipc status=unavailable error_kind={}",
                    error.kind().as_str()
                ));
            }
        });

    if spawn_result.is_err() {
        let mut log_guard = lock_log(&log);
        let _ = log_guard.write("operation=host_ui_ipc status=unavailable error_kind=thread_spawn");
    }
}
