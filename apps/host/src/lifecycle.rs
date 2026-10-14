use crate::log::{HostLog, lock_log, sanitize};
use doki_dango_platform_windows::{
    ComApartment, HOST_STARTUP_TASK_ID, InstanceAcquisition, SingleInstanceGuard,
    acquire_host_instance, current_package_full_name, host_startup_task_state, initialize_sta,
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

        {
            let mut log_guard = lock_log(&log);
            log_guard.write("operation=listener_ready status=success")?;
            log_guard.write("operation=lifecycle status=running")?;
            println!("Doki-Dango Host listener ready.");
            println!("Log: {}", log_guard.path().display());
        }

        Ok(LaunchOutcome::Primary(HostApp {
            _apartment: apartment,
            _instance: instance,
            _subscription: subscription,
            _log: log,
        }))
    }

    pub fn run(&self) -> Result<(), Box<dyn std::error::Error>> {
        loop {
            thread::sleep(Duration::from_secs(3600));
        }
    }
}
