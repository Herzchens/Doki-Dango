mod data_protection;
mod instance;
pub mod host_ui_ipc;
pub mod notifications;
mod startup;

pub use data_protection::{
    DataProtectionError, protect_for_current_user, unprotect_for_current_user,
};
pub use instance::{InstanceAcquisition, SingleInstanceGuard, acquire_host_instance};
pub use startup::{HOST_STARTUP_TASK_ID, HostStartupState, host_startup_task_state};

use windows::{
    ApplicationModel::Package,
    Win32::System::Com::{COINIT_APARTMENTTHREADED, CoInitializeEx, CoUninitialize},
};

pub struct ComApartment;

impl Drop for ComApartment {
    fn drop(&mut self) {
        unsafe { CoUninitialize() };
    }
}

pub fn initialize_sta() -> windows::core::Result<ComApartment> {
    let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
    hr.ok()?;
    Ok(ComApartment)
}

pub fn current_package_full_name() -> windows::core::Result<String> {
    Ok(Package::Current()?.Id()?.FullName()?.to_string_lossy())
}
