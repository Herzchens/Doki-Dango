mod instance;
pub mod notifications;

pub use instance::{InstanceAcquisition, SingleInstanceGuard, acquire_host_instance};

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
