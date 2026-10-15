//! Allowlisted, local-only Host health events.
//! Never add free-form strings, notification contents, credentials, FIDs or response bodies.

use std::{
    env, fs,
    fs::{File, OpenOptions},
    io::{self, Write},
    path::{Path, PathBuf},
    process,
    time::{SystemTime, UNIX_EPOCH},
};

use doki_dango_platform_windows::notifications::NotificationAccess;
use serde::Serialize;

use crate::fcm::{FcmSendReceipt, FcmSenderError};

const SCHEMA_VERSION: u8 = 1;
const MAX_SESSION_BYTES: u64 = 512 * 1024;
const MAX_SESSIONS: usize = 8;

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum AccessState {
    Allowed,
    Denied,
    Unspecified,
    Unknown,
}

impl From<NotificationAccess> for AccessState {
    fn from(status: NotificationAccess) -> Self {
        match status {
            NotificationAccess::Allowed => Self::Allowed,
            NotificationAccess::Denied => Self::Denied,
            NotificationAccess::Unspecified => Self::Unspecified,
            NotificationAccess::Unknown => Self::Unknown,
        }
    }
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FcmFailureClass {
    Credential,
    Configuration,
    Validation,
    Encoding,
    Transport,
    HttpStatus,
    Clock,
    Internal,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RemoteStage {
    OauthToken,
    FcmSend,
    Unknown,
}

#[derive(Clone, Copy, Debug, Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum DiagnosticEvent {
    HostStarting,
    ListenerAccess {
        status: AccessState,
    },
    ListenerPoll {
        count: u64,
    },
    ListenerReady,
    FcmSendAttempt,
    FcmAccepted {
        attempts: u32,
    },
    FcmFailed {
        class: FcmFailureClass,
        http_status: Option<u16>,
        remote_stage: Option<RemoteStage>,
    },
}

#[derive(Serialize)]
struct DiagnosticRecord {
    schema_version: u8,
    timestamp_unix_ms: u128,
    #[serde(flatten)]
    event: DiagnosticEvent,
}

/// Each session has a bounded JSONL file. Older files are pruned by name.
/// The caller must treat diagnostics failures as non-fatal.
pub struct Diagnostics {
    file: File,
    path: PathBuf,
    bytes_written: u64,
}

impl Diagnostics {
    pub fn open_default() -> io::Result<Self> {
        let local_app_data = env::var_os("LOCALAPPDATA")
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "LOCALAPPDATA is not set"))?;
        Self::open_in(
            PathBuf::from(local_app_data)
                .join("Doki-Dango")
                .join("Host")
                .join("diagnostics"),
        )
    }

    pub fn open_in(root: impl AsRef<Path>) -> io::Result<Self> {
        let root = root.as_ref();
        fs::create_dir_all(root)?;

        // No user-derived strings in file names or records.
        let timestamp = unix_ms();
        for suffix in 0..10 {
            let path = root.join(format!(
                "health-{timestamp:013}-{}-{suffix}.jsonl",
                process::id()
            ));
            let file = match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(file) => file,
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            };

            // Retention is best-effort: a prune failure must not prevent recording.
            prune_old_sessions(root);
            return Ok(Self {
                file,
                path,
                bytes_written: 0,
            });
        }

        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "unable to allocate unique diagnostics session",
        ))
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn record(&mut self, event: DiagnosticEvent) -> io::Result<()> {
        let record = DiagnosticRecord {
            schema_version: SCHEMA_VERSION,
            timestamp_unix_ms: unix_ms(),
            event,
        };
        let encoded = serde_json::to_vec(&record).map_err(io::Error::other)?;
        let bytes_needed = encoded.len() as u64 + 1;
        if self.bytes_written.saturating_add(bytes_needed) > MAX_SESSION_BYTES {
            return Err(io::Error::other("diagnostics session size cap reached"));
        }

        self.file.write_all(&encoded)?;
        self.file.write_all(b"\n")?;
        self.file.flush()?;
        self.bytes_written += bytes_needed;
        Ok(())
    }

    pub fn record_fcm_outcome(
        &mut self,
        result: &Result<FcmSendReceipt, FcmSenderError>,
    ) -> io::Result<()> {
        let event = match result {
            Ok(receipt) => DiagnosticEvent::FcmAccepted {
                attempts: receipt.attempts,
            },
            Err(error) => {
                let (class, http_status, remote_stage) = classify_fcm_error(error);
                DiagnosticEvent::FcmFailed {
                    class,
                    http_status,
                    remote_stage,
                }
            }
        };
        self.record(event)
    }
}

fn classify_fcm_error(
    error: &FcmSenderError,
) -> (FcmFailureClass, Option<u16>, Option<RemoteStage>) {
    match error {
        FcmSenderError::Credential(_) | FcmSenderError::MissingCredential => {
            (FcmFailureClass::Credential, None, None)
        }
        FcmSenderError::InvalidServiceAccount(_) => (FcmFailureClass::Configuration, None, None),
        FcmSenderError::InvalidTarget(_) | FcmSenderError::InvalidPayload(_) => {
            (FcmFailureClass::Validation, None, None)
        }
        FcmSenderError::Json(_) | FcmSenderError::Jwt(_) => (FcmFailureClass::Encoding, None, None),
        FcmSenderError::Transport(_) => (FcmFailureClass::Transport, None, None),
        FcmSenderError::HttpStatus { stage, status, .. } => {
            let remote_stage = match *stage {
                "oauth_token" => RemoteStage::OauthToken,
                "fcm_send" => RemoteStage::FcmSend,
                _ => RemoteStage::Unknown,
            };
            (
                FcmFailureClass::HttpStatus,
                Some(*status),
                Some(remote_stage),
            )
        }
        FcmSenderError::Clock => (FcmFailureClass::Clock, None, None),
        FcmSenderError::Poisoned => (FcmFailureClass::Internal, None, None),
    }
}

fn unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn prune_old_sessions(root: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    let mut sessions: Vec<_> = entries
        .filter_map(Result::ok)
        .filter(|entry| {
            entry.file_type().is_ok_and(|kind| kind.is_file())
                && entry
                    .file_name()
                    .to_str()
                    .is_some_and(|name| name.starts_with("health-") && name.ends_with(".jsonl"))
        })
        .map(|entry| entry.path())
        .collect();
    sessions.sort();
    let excess = sessions.len().saturating_sub(MAX_SESSIONS);
    for old in sessions.into_iter().take(excess) {
        let _ = fs::remove_file(old);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn temporary_root() -> PathBuf {
        let path = env::temp_dir().join(format!(
            "doki-diagnostics-test-{}-{}",
            process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos()
        ));
        fs::create_dir_all(&path).expect("test root");
        path
    }

    #[test]
    fn serializes_only_allowlisted_listener_fields() {
        let root = temporary_root();
        let mut diagnostics = Diagnostics::open_in(&root).expect("open");
        diagnostics
            .record(DiagnosticEvent::ListenerAccess {
                status: AccessState::Denied,
            })
            .expect("record");
        let text = fs::read_to_string(diagnostics.path()).expect("read");
        let value: Value = serde_json::from_str(text.trim()).expect("json");

        assert_eq!(value["schema_version"], 1);
        assert_eq!(value["event"], "listener_access");
        assert_eq!(value["status"], "denied");
        assert!(value["timestamp_unix_ms"].is_number());
        assert_eq!(value.as_object().expect("map").len(), 4);

        drop(diagnostics);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn fcm_acceptance_is_not_phone_delivery() {
        let root = temporary_root();
        let mut diagnostics = Diagnostics::open_in(&root).expect("open");
        diagnostics
            .record(DiagnosticEvent::FcmSendAttempt)
            .expect("attempt");
        diagnostics
            .record_fcm_outcome(&Ok(FcmSendReceipt {
                name: "sensitive-provider-message-name".to_string(),
                attempts: 2,
            }))
            .expect("accept");

        let text = fs::read_to_string(diagnostics.path()).expect("read");
        assert!(text.contains("\"event\":\"fcm_accepted\""));
        assert!(text.contains("\"attempts\":2"));
        assert!(!text.contains("sensitive-provider-message-name"));
        assert!(!text.contains("delivered"));
        assert!(!text.contains("online"));

        drop(diagnostics);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn errors_do_not_write_free_form_messages() {
        let root = temporary_root();
        let mut diagnostics = Diagnostics::open_in(&root).expect("open");
        diagnostics
            .record_fcm_outcome(&Err(FcmSenderError::Transport(
                "sensitive-fid-bearer-or-response-body".to_string(),
            )))
            .expect("record");

        let text = fs::read_to_string(diagnostics.path()).expect("read");
        assert!(text.contains("\"class\":\"transport\""));
        assert!(!text.contains("sensitive-fid-bearer-or-response-body"));

        drop(diagnostics);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn records_http_code_but_not_server_response() {
        let root = temporary_root();
        let mut diagnostics = Diagnostics::open_in(&root).expect("open");
        diagnostics
            .record_fcm_outcome(&Err(FcmSenderError::HttpStatus {
                stage: "fcm_send",
                status: 429,
                retry_after_seconds: Some(90),
            }))
            .expect("record");

        let text = fs::read_to_string(diagnostics.path()).expect("read");
        let value: Value = serde_json::from_str(text.trim()).expect("json");
        assert_eq!(value["http_status"], 429);
        assert_eq!(value["remote_stage"], "fcm_send");
        assert_eq!(value.as_object().expect("map").len(), 6);

        drop(diagnostics);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn session_size_is_bounded() {
        let root = temporary_root();
        let mut diagnostics = Diagnostics::open_in(&root).expect("open");
        let mut reached_cap = false;
        for _ in 0..10_000 {
            if diagnostics.record(DiagnosticEvent::HostStarting).is_err() {
                reached_cap = true;
                break;
            }
        }
        assert!(reached_cap);
        assert!(fs::metadata(diagnostics.path()).expect("metadata").len() <= MAX_SESSION_BYTES);

        drop(diagnostics);
        fs::remove_dir_all(root).expect("cleanup");
    }
}
