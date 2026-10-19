use serde::{Deserialize, Serialize};
use std::{
    error::Error,
    ffi::c_void,
    fmt,
    iter,
    mem::size_of,
    os::windows::ffi::OsStrExt,
};
use windows::{
    Win32::{
        Foundation::{
            CloseHandle, ERROR_MORE_DATA, ERROR_PIPE_CONNECTED, HANDLE, HLOCAL, LocalFree,
            WIN32_ERROR,
        },
        Security::{
            Authorization::{
                ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1,
            },
            PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES,
        },
        Storage::FileSystem::{
            FILE_FLAG_FIRST_PIPE_INSTANCE, FlushFileBuffers, PIPE_ACCESS_DUPLEX, ReadFile,
            WriteFile,
        },
        System::Pipes::{
            CallNamedPipeW, ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe,
            PIPE_READMODE_MESSAGE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_MESSAGE, PIPE_WAIT,
        },
    },
    core::{Error as WindowsError, PCWSTR, w},
};

pub const HOST_UI_IPC_VERSION: u32 = 1;
pub const HOST_UI_PIPE_NAME: &str =
    r"\\.\pipe\LOCAL\ItzHerzchen.DokiDango.HostUi.v1";

const HOST_STATUS_KIND: &str = "host_status";
const HOST_RUNNING_STATE: &str = "running";
const IPC_MAX_MESSAGE_BYTES: usize = 4096;
const IPC_TIMEOUT_MS: u32 = 5_000;
const PIPE_SECURITY_SDDL: &str = "D:P(A;;GA;;;SY)(A;;GA;;;OW)";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostUiIpcErrorKind {
    SecurityDescriptor,
    Bind,
    Connect,
    Read,
    Write,
    Flush,
    Disconnect,
    MessageTooLarge,
    InvalidRequest,
    UnsupportedVersion,
    UnsupportedKind,
    ClientUnavailable,
    InvalidResponse,
}

impl HostUiIpcErrorKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::SecurityDescriptor => "security_descriptor",
            Self::Bind => "bind",
            Self::Connect => "connect",
            Self::Read => "read",
            Self::Write => "write",
            Self::Flush => "flush",
            Self::Disconnect => "disconnect",
            Self::MessageTooLarge => "message_too_large",
            Self::InvalidRequest => "invalid_request",
            Self::UnsupportedVersion => "unsupported_version",
            Self::UnsupportedKind => "unsupported_kind",
            Self::ClientUnavailable => "client_unavailable",
            Self::InvalidResponse => "invalid_response",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HostUiIpcError {
    kind: HostUiIpcErrorKind,
}

impl HostUiIpcError {
    const fn new(kind: HostUiIpcErrorKind) -> Self {
        Self { kind }
    }

    pub const fn kind(&self) -> HostUiIpcErrorKind {
        self.kind
    }
}

impl fmt::Display for HostUiIpcError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.kind.as_str())
    }
}

impl Error for HostUiIpcError {}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct HostUiRequest {
    ipc_version: u32,
    request_id: u64,
    kind: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HostStatusResponse {
    pub ipc_version: u32,
    pub request_id: u64,
    pub kind: String,
    pub host_state: String,
}

struct LocalSecurityDescriptor {
    value: PSECURITY_DESCRIPTOR,
}

impl LocalSecurityDescriptor {
    fn protected_for_creator() -> Result<Self, HostUiIpcError> {
        debug_assert_eq!(
            PIPE_SECURITY_SDDL,
            "D:P(A;;GA;;;SY)(A;;GA;;;OW)"
        );

        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        unsafe {
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                w!("D:P(A;;GA;;;SY)(A;;GA;;;OW)"),
                SDDL_REVISION_1,
                &mut descriptor,
                None,
            )
        }
        .map_err(|_| HostUiIpcError::new(HostUiIpcErrorKind::SecurityDescriptor))?;

        if descriptor.is_invalid() {
            return Err(HostUiIpcError::new(
                HostUiIpcErrorKind::SecurityDescriptor,
            ));
        }

        Ok(Self { value: descriptor })
    }

    fn security_attributes(&self) -> SECURITY_ATTRIBUTES {
        SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.value.0,
            ..Default::default()
        }
    }
}

impl Drop for LocalSecurityDescriptor {
    fn drop(&mut self) {
        if !self.value.is_invalid() {
            unsafe {
                let _ = LocalFree(Some(HLOCAL(self.value.0)));
            }
        }
    }
}

pub struct HostUiIpcServer {
    handle: HANDLE,
}

impl HostUiIpcServer {
    pub fn bind_default() -> Result<Self, HostUiIpcError> {
        Self::bind(HOST_UI_PIPE_NAME)
    }

    fn bind(pipe_name: &str) -> Result<Self, HostUiIpcError> {
        let security = LocalSecurityDescriptor::protected_for_creator()?;
        let attributes = security.security_attributes();
        let pipe_name = wide(pipe_name);

        let handle = unsafe {
            CreateNamedPipeW(
                PCWSTR(pipe_name.as_ptr()),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_MESSAGE
                    | PIPE_READMODE_MESSAGE
                    | PIPE_WAIT
                    | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                IPC_MAX_MESSAGE_BYTES as u32,
                IPC_MAX_MESSAGE_BYTES as u32,
                IPC_TIMEOUT_MS,
                Some(&attributes),
            )
        };

        if handle.is_invalid() {
            return Err(HostUiIpcError::new(HostUiIpcErrorKind::Bind));
        }

        Ok(Self { handle })
    }

    pub fn serve_once(&self) -> Result<(), HostUiIpcError> {
        self.connect()?;

        let transaction_result = self.process_connected_client();
        let flush_result = if transaction_result.is_ok() {
            unsafe { FlushFileBuffers(self.handle) }
                .map_err(|_| HostUiIpcError::new(HostUiIpcErrorKind::Flush))
        } else {
            Ok(())
        };
        let disconnect_result = unsafe { DisconnectNamedPipe(self.handle) }
            .map_err(|_| HostUiIpcError::new(HostUiIpcErrorKind::Disconnect));

        transaction_result?;
        flush_result?;
        disconnect_result
    }

    fn connect(&self) -> Result<(), HostUiIpcError> {
        match unsafe { ConnectNamedPipe(self.handle, None) } {
            Ok(()) => Ok(()),
            Err(error)
                if WIN32_ERROR::from_error(&error) == Some(ERROR_PIPE_CONNECTED) =>
            {
                Ok(())
            }
            Err(_) => Err(HostUiIpcError::new(HostUiIpcErrorKind::Connect)),
        }
    }

    fn process_connected_client(&self) -> Result<(), HostUiIpcError> {
        let mut request_buffer = [0u8; IPC_MAX_MESSAGE_BYTES];
        let mut bytes_read = 0u32;

        match unsafe {
            ReadFile(
                self.handle,
                Some(&mut request_buffer),
                Some(&mut bytes_read),
                None,
            )
        } {
            Ok(()) => {}
            Err(error) if WIN32_ERROR::from_error(&error) == Some(ERROR_MORE_DATA) => {
                return Err(HostUiIpcError::new(
                    HostUiIpcErrorKind::MessageTooLarge,
                ));
            }
            Err(_) => return Err(HostUiIpcError::new(HostUiIpcErrorKind::Read)),
        }

        let request_len = usize::try_from(bytes_read)
            .map_err(|_| HostUiIpcError::new(HostUiIpcErrorKind::MessageTooLarge))?;
        let response = handle_request(&request_buffer[..request_len])?;

        let mut bytes_written = 0u32;
        unsafe {
            WriteFile(
                self.handle,
                Some(&response),
                Some(&mut bytes_written),
                None,
            )
        }
        .map_err(|_| HostUiIpcError::new(HostUiIpcErrorKind::Write))?;

        if usize::try_from(bytes_written).ok() != Some(response.len()) {
            return Err(HostUiIpcError::new(HostUiIpcErrorKind::Write));
        }

        Ok(())
    }
}

impl Drop for HostUiIpcServer {
    fn drop(&mut self) {
        if !self.handle.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.handle);
            }
        }
    }
}

pub fn query_host_status(request_id: u64) -> Result<HostStatusResponse, HostUiIpcError> {
    query_host_status_at(HOST_UI_PIPE_NAME, request_id)
}

fn query_host_status_at(
    pipe_name: &str,
    request_id: u64,
) -> Result<HostStatusResponse, HostUiIpcError> {
    let request = HostUiRequest {
        ipc_version: HOST_UI_IPC_VERSION,
        request_id,
        kind: HOST_STATUS_KIND.to_string(),
    };
    let request = serde_json::to_vec(&request)
        .map_err(|_| HostUiIpcError::new(HostUiIpcErrorKind::InvalidRequest))?;
    if request.len() > IPC_MAX_MESSAGE_BYTES {
        return Err(HostUiIpcError::new(
            HostUiIpcErrorKind::MessageTooLarge,
        ));
    }

    let pipe_name = wide(pipe_name);
    let mut response_buffer = [0u8; IPC_MAX_MESSAGE_BYTES];
    let mut bytes_read = 0u32;

    let call_result = unsafe {
        CallNamedPipeW(
            PCWSTR(pipe_name.as_ptr()),
            Some(request.as_ptr().cast::<c_void>()),
            request.len() as u32,
            Some(response_buffer.as_mut_ptr().cast::<c_void>()),
            IPC_MAX_MESSAGE_BYTES as u32,
            &mut bytes_read,
            IPC_TIMEOUT_MS,
        )
    };

    if !call_result.as_bool() {
        let error = WindowsError::from_win32();
        if WIN32_ERROR::from_error(&error) == Some(ERROR_MORE_DATA) {
            return Err(HostUiIpcError::new(
                HostUiIpcErrorKind::MessageTooLarge,
            ));
        }
        return Err(HostUiIpcError::new(
            HostUiIpcErrorKind::ClientUnavailable,
        ));
    }

    let response_len = usize::try_from(bytes_read)
        .map_err(|_| HostUiIpcError::new(HostUiIpcErrorKind::InvalidResponse))?;
    parse_response(&response_buffer[..response_len], request_id)
}

fn handle_request(request: &[u8]) -> Result<Vec<u8>, HostUiIpcError> {
    if request.is_empty() || request.len() > IPC_MAX_MESSAGE_BYTES {
        return Err(HostUiIpcError::new(
            HostUiIpcErrorKind::MessageTooLarge,
        ));
    }

    let request: HostUiRequest = serde_json::from_slice(request)
        .map_err(|_| HostUiIpcError::new(HostUiIpcErrorKind::InvalidRequest))?;

    if request.ipc_version != HOST_UI_IPC_VERSION {
        return Err(HostUiIpcError::new(
            HostUiIpcErrorKind::UnsupportedVersion,
        ));
    }
    if request.kind != HOST_STATUS_KIND {
        return Err(HostUiIpcError::new(
            HostUiIpcErrorKind::UnsupportedKind,
        ));
    }

    let response = HostStatusResponse {
        ipc_version: HOST_UI_IPC_VERSION,
        request_id: request.request_id,
        kind: HOST_STATUS_KIND.to_string(),
        host_state: HOST_RUNNING_STATE.to_string(),
    };

    let encoded = serde_json::to_vec(&response)
        .map_err(|_| HostUiIpcError::new(HostUiIpcErrorKind::InvalidResponse))?;
    if encoded.len() > IPC_MAX_MESSAGE_BYTES {
        return Err(HostUiIpcError::new(
            HostUiIpcErrorKind::MessageTooLarge,
        ));
    }

    Ok(encoded)
}

fn parse_response(
    response: &[u8],
    expected_request_id: u64,
) -> Result<HostStatusResponse, HostUiIpcError> {
    let response: HostStatusResponse = serde_json::from_slice(response)
        .map_err(|_| HostUiIpcError::new(HostUiIpcErrorKind::InvalidResponse))?;

    if response.ipc_version != HOST_UI_IPC_VERSION
        || response.request_id != expected_request_id
        || response.kind != HOST_STATUS_KIND
        || response.host_state != HOST_RUNNING_STATE
    {
        return Err(HostUiIpcError::new(
            HostUiIpcErrorKind::InvalidResponse,
        ));
    }

    Ok(response)
}

fn wide(value: &str) -> Vec<u16> {
    std::ffi::OsStr::new(value)
        .encode_wide()
        .chain(iter::once(0))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        process,
        sync::{
            atomic::{AtomicU64, Ordering},
            mpsc,
        },
        thread,
        time::Duration,
    };

    static PIPE_COUNTER: AtomicU64 = AtomicU64::new(1);

    #[test]
    fn valid_request_produces_versioned_status_response() {
        let response = handle_request(
            br#"{"ipc_version":1,"request_id":42,"kind":"host_status"}"#,
        )
        .expect("valid request");

        let response = parse_response(&response, 42).expect("valid response");
        assert_eq!(response.ipc_version, HOST_UI_IPC_VERSION);
        assert_eq!(response.request_id, 42);
        assert_eq!(response.kind, HOST_STATUS_KIND);
        assert_eq!(response.host_state, HOST_RUNNING_STATE);
    }

    #[test]
    fn unsupported_version_is_rejected() {
        let error = handle_request(
            br#"{"ipc_version":2,"request_id":42,"kind":"host_status"}"#,
        )
        .expect_err("unsupported version must fail");
        assert_eq!(error.kind(), HostUiIpcErrorKind::UnsupportedVersion);
    }

    #[test]
    fn unsupported_kind_is_rejected() {
        let error = handle_request(
            br#"{"ipc_version":1,"request_id":42,"kind":"shutdown"}"#,
        )
        .expect_err("unsupported kind must fail");
        assert_eq!(error.kind(), HostUiIpcErrorKind::UnsupportedKind);
    }

    #[test]
    fn unknown_request_fields_are_rejected() {
        let error = handle_request(
            br#"{"ipc_version":1,"request_id":42,"kind":"host_status","extra":true}"#,
        )
        .expect_err("unknown fields must fail");
        assert_eq!(error.kind(), HostUiIpcErrorKind::InvalidRequest);
    }

    #[test]
    fn local_named_pipe_round_trip_returns_host_status() {
        let suffix = PIPE_COUNTER.fetch_add(1, Ordering::Relaxed);
        let pipe_name = format!(
            r"\\.\pipe\LOCAL\DokiDango.Test.HostUi.{}.{}",
            process::id(),
            suffix
        );

        let server_pipe_name = pipe_name.clone();
        let (ready_tx, ready_rx) = mpsc::channel();
        let server_thread = thread::spawn(move || {
            let server =
                HostUiIpcServer::bind(&server_pipe_name).expect("bind test pipe");
            ready_tx.send(()).expect("signal test server ready");
            server.serve_once().expect("serve one test request");
        });

        ready_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("test server readiness");

        let response = query_host_status_at(&pipe_name, 7).expect("query host status");
        assert_eq!(response.request_id, 7);
        assert_eq!(response.host_state, HOST_RUNNING_STATE);

        server_thread.join().expect("join test server");
    }
}
