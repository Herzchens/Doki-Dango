use windows::{
    ApplicationModel::{StartupTask, StartupTaskState},
    core::HSTRING,
};

pub const HOST_STARTUP_TASK_ID: &str = "DokiDangoHostStartup";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostStartupState {
    Disabled,
    DisabledByUser,
    Enabled,
    DisabledByPolicy,
    EnabledByPolicy,
    Unknown,
}

impl HostStartupState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "Disabled",
            Self::DisabledByUser => "DisabledByUser",
            Self::Enabled => "Enabled",
            Self::DisabledByPolicy => "DisabledByPolicy",
            Self::EnabledByPolicy => "EnabledByPolicy",
            Self::Unknown => "Unknown",
        }
    }
}

pub fn host_startup_task_state() -> windows::core::Result<HostStartupState> {
    let task_id = HSTRING::from(HOST_STARTUP_TASK_ID);
    let task = StartupTask::GetAsync(&task_id)?.join()?;
    Ok(map_startup_state(task.State()?))
}

fn map_startup_state(state: StartupTaskState) -> HostStartupState {
    if state == StartupTaskState::Disabled {
        HostStartupState::Disabled
    } else if state == StartupTaskState::DisabledByUser {
        HostStartupState::DisabledByUser
    } else if state == StartupTaskState::Enabled {
        HostStartupState::Enabled
    } else if state == StartupTaskState::DisabledByPolicy {
        HostStartupState::DisabledByPolicy
    } else if state == StartupTaskState::EnabledByPolicy {
        HostStartupState::EnabledByPolicy
    } else {
        HostStartupState::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_known_startup_states() {
        assert_eq!(
            map_startup_state(StartupTaskState::Disabled),
            HostStartupState::Disabled
        );
        assert_eq!(
            map_startup_state(StartupTaskState::DisabledByUser),
            HostStartupState::DisabledByUser
        );
        assert_eq!(
            map_startup_state(StartupTaskState::Enabled),
            HostStartupState::Enabled
        );
        assert_eq!(
            map_startup_state(StartupTaskState::DisabledByPolicy),
            HostStartupState::DisabledByPolicy
        );
        assert_eq!(
            map_startup_state(StartupTaskState::EnabledByPolicy),
            HostStartupState::EnabledByPolicy
        );
    }
}
