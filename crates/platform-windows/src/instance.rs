use windows::{
    Win32::{
        Foundation::{CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE},
        System::Threading::CreateMutexW,
    },
    core::{PCWSTR, Result, w},
};

const HOST_MUTEX_NAME: PCWSTR = w!("Local\\ItzHerzchen.DokiDango.Host.Instance");

pub struct SingleInstanceGuard {
    handle: HANDLE,
}

impl SingleInstanceGuard {
    fn new(handle: HANDLE) -> Self {
        Self { handle }
    }
}

impl Drop for SingleInstanceGuard {
    fn drop(&mut self) {
        if !self.handle.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.handle);
            }
        }
    }
}

pub enum InstanceAcquisition {
    Primary(SingleInstanceGuard),
    AlreadyRunning,
}

fn try_acquire_single_instance(name: PCWSTR) -> Result<InstanceAcquisition> {
    let handle = unsafe { CreateMutexW(None, false, name)? };
    let last_error = unsafe { GetLastError() };

    if last_error == ERROR_ALREADY_EXISTS {
        unsafe {
            let _ = CloseHandle(handle);
        }
        Ok(InstanceAcquisition::AlreadyRunning)
    } else {
        Ok(InstanceAcquisition::Primary(SingleInstanceGuard::new(
            handle,
        )))
    }
}

pub fn acquire_host_instance() -> Result<InstanceAcquisition> {
    try_acquire_single_instance(HOST_MUTEX_NAME)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::iter;

    fn unique_test_mutex_name() -> Vec<u16> {
        format!(
            "Local\\DokiDango.Test.Lifecycle.Instance.{}",
            std::process::id()
        )
        .encode_utf16()
        .chain(iter::once(0))
        .collect()
    }

    #[test]
    fn single_instance_lifecycle_acquisition_and_release() {
        let mutex_name = unique_test_mutex_name();
        let mutex_name = PCWSTR(mutex_name.as_ptr());

        let first = try_acquire_single_instance(mutex_name).expect("acquire first");
        let guard = match first {
            InstanceAcquisition::Primary(guard) => guard,
            InstanceAcquisition::AlreadyRunning => {
                panic!("expected primary on first acquisition");
            }
        };

        let second = try_acquire_single_instance(mutex_name).expect("acquire second");
        assert!(matches!(second, InstanceAcquisition::AlreadyRunning));

        drop(guard);

        let third = try_acquire_single_instance(mutex_name).expect("acquire third");
        assert!(matches!(third, InstanceAcquisition::Primary(_)));
    }
}
