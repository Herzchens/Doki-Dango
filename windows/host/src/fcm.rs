use std::{
    collections::BTreeMap,
    error::Error as StdError,
    fmt,
    sync::Mutex,
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use jsonwebtoken::{Algorithm, EncodingKey, Header, encode};
use serde::{Deserialize, Serialize};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::credentials::{CredentialStoreError, ProtectedCredentialFile};

const OAUTH_TOKEN_URI: &str = "https://oauth2.googleapis.com/token";
const FCM_SCOPE: &str = "https://www.googleapis.com/auth/firebase.messaging";
const FCM_SEND_ROOT: &str = "https://fcm.googleapis.com/v1/projects";
const MAX_DATA_JSON_BYTES: usize = 4096;
const TOKEN_REFRESH_SKEW_SECONDS: u64 = 300;
const JWT_LIFETIME_SECONDS: u64 = 3600;
const DEFAULT_TTL_SECONDS: u32 = 60;
const MAX_SEND_ATTEMPTS: u32 = 3;

#[derive(Debug)]
pub enum FcmSenderError {
    Credential(CredentialStoreError),
    MissingCredential,
    InvalidServiceAccount(&'static str),
    InvalidTarget(&'static str),
    InvalidPayload(&'static str),
    Json(serde_json::Error),
    Jwt(jsonwebtoken::errors::Error),
    Transport(String),
    HttpStatus {
        stage: &'static str,
        status: u16,
        retry_after_seconds: Option<u64>,
    },
    Clock,
    Poisoned,
}

impl fmt::Display for FcmSenderError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Credential(error) => write!(formatter, "credential load failed: {error}"),
            Self::MissingCredential => {
                formatter.write_str("protected Firebase credential is missing")
            }
            Self::InvalidServiceAccount(reason) => {
                write!(formatter, "Firebase service account is invalid: {reason}")
            }
            Self::InvalidTarget(reason) => write!(formatter, "FCM target is invalid: {reason}"),
            Self::InvalidPayload(reason) => write!(formatter, "FCM payload is invalid: {reason}"),
            Self::Json(error) => write!(formatter, "JSON processing failed: {error}"),
            Self::Jwt(error) => write!(formatter, "service-account JWT creation failed: {error}"),
            Self::Transport(error) => write!(formatter, "FCM transport failed: {error}"),
            Self::HttpStatus {
                stage,
                status,
                retry_after_seconds,
            } => {
                write!(formatter, "{stage} returned HTTP {status}")?;
                if let Some(seconds) = retry_after_seconds {
                    write!(formatter, " (retry after {seconds}s)")?;
                }
                Ok(())
            }
            Self::Clock => formatter.write_str("system clock is before the Unix epoch"),
            Self::Poisoned => formatter.write_str("FCM access-token cache is poisoned"),
        }
    }
}

impl StdError for FcmSenderError {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        match self {
            Self::Credential(error) => Some(error),
            Self::Json(error) => Some(error),
            Self::Jwt(error) => Some(error),
            _ => None,
        }
    }
}

impl From<CredentialStoreError> for FcmSenderError {
    fn from(error: CredentialStoreError) -> Self {
        Self::Credential(error)
    }
}

impl From<serde_json::Error> for FcmSenderError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

impl From<jsonwebtoken::errors::Error> for FcmSenderError {
    fn from(error: jsonwebtoken::errors::Error) -> Self {
        Self::Jwt(error)
    }
}

#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
struct ServiceAccountJson {
    #[serde(rename = "type")]
    account_type: String,
    project_id: String,
    private_key_id: String,
    private_key: String,
    client_email: String,
    token_uri: String,
}

struct ServiceAccountAuth {
    project_id: String,
    client_email: String,
    private_key_id: String,
    encoding_key: EncodingKey,
}

struct CachedAccessToken {
    value: Zeroizing<String>,
    expires_at_epoch_seconds: u64,
}

#[derive(Deserialize, Zeroize, ZeroizeOnDrop)]
struct OAuthTokenResponse {
    access_token: String,
    expires_in: u64,
    token_type: String,
}

#[derive(Serialize)]
struct OAuthClaims<'a> {
    iss: &'a str,
    scope: &'static str,
    aud: &'static str,
    iat: u64,
    exp: u64,
}

#[derive(Clone)]
pub struct FcmDataMessage {
    pub fid: String,
    pub data: BTreeMap<String, String>,
    pub android_package_name: Option<String>,
    pub ttl_seconds: u32,
}

impl FcmDataMessage {
    pub fn new(fid: impl Into<String>, data: BTreeMap<String, String>) -> Self {
        Self {
            fid: fid.into(),
            data,
            android_package_name: None,
            ttl_seconds: DEFAULT_TTL_SECONDS,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FcmSendReceipt {
    pub name: String,
    pub attempts: u32,
}

#[derive(Serialize)]
struct SendRequest<'a> {
    message: SendMessage<'a>,
}

#[derive(Serialize)]
struct SendMessage<'a> {
    fid: &'a str,
    data: &'a BTreeMap<String, String>,
    android: AndroidConfig<'a>,
}

#[derive(Serialize)]
struct AndroidConfig<'a> {
    priority: &'static str,
    ttl: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    restricted_package_name: Option<&'a str>,
}

#[derive(Deserialize)]
struct SendResponse {
    name: String,
}

pub struct FcmSender {
    agent: ureq::Agent,
    auth: ServiceAccountAuth,
    access_token: Mutex<Option<CachedAccessToken>>,
}

impl FcmSender {
    pub fn from_default_credential_file() -> Result<Self, FcmSenderError> {
        let store = ProtectedCredentialFile::firebase_service_account()
            .map_err(CredentialStoreError::from)?;
        Self::from_protected_credential_file(&store)
    }

    pub fn from_protected_credential_file(
        store: &ProtectedCredentialFile,
    ) -> Result<Self, FcmSenderError> {
        let protected = store.load()?.ok_or(FcmSenderError::MissingCredential)?;
        Self::from_service_account_json(protected.as_bytes())
    }

    pub fn from_service_account_json(json: &[u8]) -> Result<Self, FcmSenderError> {
        let service_account: ServiceAccountJson = serde_json::from_slice(json)?;
        validate_service_account(&service_account)?;

        let encoding_key = EncodingKey::from_rsa_pem(service_account.private_key.as_bytes())?;
        let auth = ServiceAccountAuth {
            project_id: service_account.project_id.clone(),
            client_email: service_account.client_email.clone(),
            private_key_id: service_account.private_key_id.clone(),
            encoding_key,
        };

        let config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(15)))
            .http_status_as_error(false)
            .build();

        Ok(Self {
            agent: config.into(),
            auth,
            access_token: Mutex::new(None),
        })
    }

    pub fn project_id(&self) -> &str {
        &self.auth.project_id
    }

    pub fn send(&self, message: &FcmDataMessage) -> Result<FcmSendReceipt, FcmSenderError> {
        validate_message(message)?;

        let mut attempts = 0;
        let mut refreshed_after_unauthorized = false;

        loop {
            attempts += 1;
            let token = self.access_token()?;
            let result = self.send_once(message, token.as_str());

            match result {
                Ok(name) => return Ok(FcmSendReceipt { name, attempts }),
                Err(FcmSenderError::HttpStatus { status: 401, .. })
                    if !refreshed_after_unauthorized =>
                {
                    self.invalidate_access_token()?;
                    refreshed_after_unauthorized = true;
                }
                Err(FcmSenderError::HttpStatus {
                    stage: "fcm_send",
                    status,
                    retry_after_seconds,
                }) if attempts < MAX_SEND_ATTEMPTS && is_retryable_send_status(status) => {
                    let delay = retry_delay(status, attempts, retry_after_seconds);
                    thread::sleep(delay);
                }
                Err(error) => return Err(error),
            }
        }
    }

    fn access_token(&self) -> Result<Zeroizing<String>, FcmSenderError> {
        let now = epoch_seconds()?;
        {
            let cache = self
                .access_token
                .lock()
                .map_err(|_| FcmSenderError::Poisoned)?;

            if let Some(token) = cache.as_ref()
                && now.saturating_add(TOKEN_REFRESH_SKEW_SECONDS) < token.expires_at_epoch_seconds
            {
                return Ok(Zeroizing::new(token.value.to_string()));
            }
        }

        let token = self.request_access_token(now)?;
        let result = Zeroizing::new(token.value.to_string());

        let mut cache = self
            .access_token
            .lock()
            .map_err(|_| FcmSenderError::Poisoned)?;
        *cache = Some(token);

        Ok(result)
    }

    fn request_access_token(&self, now: u64) -> Result<CachedAccessToken, FcmSenderError> {
        let claims = OAuthClaims {
            iss: &self.auth.client_email,
            scope: FCM_SCOPE,
            aud: OAUTH_TOKEN_URI,
            iat: now,
            exp: now.saturating_add(JWT_LIFETIME_SECONDS),
        };
        let mut header = Header::new(Algorithm::RS256);
        if !self.auth.private_key_id.is_empty() {
            header.kid = Some(self.auth.private_key_id.clone());
        }

        let assertion = Zeroizing::new(encode(&header, &claims, &self.auth.encoding_key)?);
        let mut response = self
            .agent
            .post(OAUTH_TOKEN_URI)
            .send_form([
                ("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
                ("assertion", assertion.as_str()),
            ])
            .map_err(transport_error)?;

        let status = response.status().as_u16();
        if !(200..300).contains(&status) {
            return Err(http_status_error("oauth_token", status, &response));
        }

        let mut token_response: OAuthTokenResponse = response
            .body_mut()
            .read_json()
            .map_err(|error| FcmSenderError::Transport(error.to_string()))?;

        if token_response.access_token.is_empty() {
            return Err(FcmSenderError::InvalidServiceAccount(
                "OAuth token response contains an empty access token",
            ));
        }
        if !token_response.token_type.eq_ignore_ascii_case("Bearer") {
            return Err(FcmSenderError::InvalidServiceAccount(
                "OAuth token response is not Bearer",
            ));
        }

        let expires_in = token_response.expires_in;
        let access_token = Zeroizing::new(std::mem::take(&mut token_response.access_token));

        Ok(CachedAccessToken {
            value: access_token,
            expires_at_epoch_seconds: now.saturating_add(expires_in),
        })
    }

    fn send_once(
        &self,
        message: &FcmDataMessage,
        access_token: &str,
    ) -> Result<String, FcmSenderError> {
        let request = SendRequest {
            message: SendMessage {
                fid: message.fid.trim(),
                data: &message.data,
                android: AndroidConfig {
                    priority: "HIGH",
                    ttl: format!("{}s", message.ttl_seconds),
                    restricted_package_name: message.android_package_name.as_deref(),
                },
            },
        };

        let uri = format!("{}/{}/messages:send", FCM_SEND_ROOT, self.auth.project_id);
        let authorization = Zeroizing::new(format!("Bearer {access_token}"));

        let mut response = self
            .agent
            .post(&uri)
            .header("Authorization", authorization.as_str())
            .send_json(&request)
            .map_err(transport_error)?;

        let status = response.status().as_u16();
        if !(200..300).contains(&status) {
            return Err(http_status_error("fcm_send", status, &response));
        }

        let send_response: SendResponse = response
            .body_mut()
            .read_json()
            .map_err(|error| FcmSenderError::Transport(error.to_string()))?;

        if send_response.name.is_empty() {
            return Err(FcmSenderError::Transport(
                "FCM success response omitted message name".to_string(),
            ));
        }

        Ok(send_response.name)
    }

    fn invalidate_access_token(&self) -> Result<(), FcmSenderError> {
        let mut cache = self
            .access_token
            .lock()
            .map_err(|_| FcmSenderError::Poisoned)?;
        *cache = None;
        Ok(())
    }
}

fn validate_service_account(value: &ServiceAccountJson) -> Result<(), FcmSenderError> {
    if value.account_type != "service_account" {
        return Err(FcmSenderError::InvalidServiceAccount(
            "type must be service_account",
        ));
    }
    if value.project_id.trim().is_empty()
        || !value
            .project_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | ':' | '.'))
    {
        return Err(FcmSenderError::InvalidServiceAccount(
            "project_id is missing or contains unsupported characters",
        ));
    }
    if value.client_email.trim().is_empty() || !value.client_email.contains('@') {
        return Err(FcmSenderError::InvalidServiceAccount(
            "client_email is missing or malformed",
        ));
    }
    if !value.private_key.contains("BEGIN PRIVATE KEY") {
        return Err(FcmSenderError::InvalidServiceAccount(
            "private_key is missing or is not PKCS#8 PEM",
        ));
    }
    if value.token_uri != OAUTH_TOKEN_URI {
        return Err(FcmSenderError::InvalidServiceAccount(
            "token_uri must be the Google OAuth token endpoint",
        ));
    }
    Ok(())
}

fn validate_message(message: &FcmDataMessage) -> Result<(), FcmSenderError> {
    let fid = message.fid.trim();
    if fid.is_empty() {
        return Err(FcmSenderError::InvalidTarget("FID is empty"));
    }
    if fid.len() > 4096 || fid.chars().any(char::is_control) {
        return Err(FcmSenderError::InvalidTarget(
            "FID is too large or contains control characters",
        ));
    }
    if message.data.is_empty() {
        return Err(FcmSenderError::InvalidPayload("data payload is empty"));
    }
    if message.data.keys().any(|key| key.is_empty()) {
        return Err(FcmSenderError::InvalidPayload(
            "data payload contains an empty key",
        ));
    }
    if message.data.keys().any(|key| is_reserved_data_key(key)) {
        return Err(FcmSenderError::InvalidPayload(
            "data payload contains an FCM-reserved key",
        ));
    }

    let serialized = serde_json::to_vec(&message.data)?;
    if serialized.len() > MAX_DATA_JSON_BYTES {
        return Err(FcmSenderError::InvalidPayload(
            "serialized data payload exceeds 4096 bytes",
        ));
    }
    if message.ttl_seconds == 0 {
        return Err(FcmSenderError::InvalidPayload("TTL must be non-zero"));
    }
    if let Some(package_name) = message.android_package_name.as_deref()
        && (package_name.trim().is_empty() || package_name.chars().any(char::is_whitespace))
    {
        return Err(FcmSenderError::InvalidPayload(
            "Android package name is malformed",
        ));
    }

    Ok(())
}

fn is_reserved_data_key(key: &str) -> bool {
    key == "from"
        || key == "message_type"
        || key.starts_with("google.")
        || key.starts_with("gcm.notification.")
}

fn transport_error(error: ureq::Error) -> FcmSenderError {
    FcmSenderError::Transport(error.to_string())
}

fn http_status_error(
    stage: &'static str,
    status: u16,
    response: &ureq::http::Response<ureq::Body>,
) -> FcmSenderError {
    let retry_after_seconds = response
        .headers()
        .get("retry-after")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.trim().parse::<u64>().ok());

    FcmSenderError::HttpStatus {
        stage,
        status,
        retry_after_seconds,
    }
}

fn is_retryable_send_status(status: u16) -> bool {
    status == 429 || (500..=599).contains(&status)
}

fn retry_delay(status: u16, attempt: u32, retry_after_seconds: Option<u64>) -> Duration {
    let base_seconds = if let Some(retry_after_seconds) = retry_after_seconds {
        if status == 429 {
            retry_after_seconds.max(60)
        } else {
            retry_after_seconds.max(10)
        }
    } else if status == 429 {
        60
    } else {
        10_u64.saturating_mul(1_u64 << attempt.saturating_sub(1).min(4))
    };

    let jitter_basis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .subsec_millis() as u64;
    let jitter_millis = jitter_basis % 1000;

    Duration::from_millis(base_seconds.saturating_mul(1000) + jitter_millis)
}

fn epoch_seconds() -> Result<u64, FcmSenderError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .map_err(|_| FcmSenderError::Clock)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn valid_service_account_json() -> Vec<u8> {
        let key_type = ["PRIVATE", "KEY"].join(" ");
        let private_key =
            format!("-----BEGIN {key_type}-----\\nSYNTHETIC\\n-----END {key_type}-----\\n");

        serde_json::to_vec(&serde_json::json!({
            "type": "service_account",
            "project_id": "doki-test-project",
            "private_key_id": "synthetic-key-id",
            "private_key": private_key,
            "client_email": "sender@doki-test-project.iam.gserviceaccount.com",
            "token_uri": "https://oauth2.googleapis.com/token"
        }))
        .expect("serialize service account")
    }

    #[test]
    fn rejects_non_google_token_uri_before_key_parsing() {
        let mut value: serde_json::Value =
            serde_json::from_slice(&valid_service_account_json()).expect("json");
        value["token_uri"] = serde_json::Value::String("https://example.invalid/token".to_string());
        let json = serde_json::to_vec(&value).expect("serialize");

        let error = match FcmSender::from_service_account_json(&json) {
            Ok(_) => panic!("unexpected success"),
            Err(error) => error,
        };

        assert!(matches!(
            error,
            FcmSenderError::InvalidServiceAccount(
                "token_uri must be the Google OAuth token endpoint"
            )
        ));
    }

    #[test]
    fn serializes_fid_data_only_request() {
        let mut data = BTreeMap::new();
        data.insert("kind".to_string(), "synthetic".to_string());
        let message = FcmDataMessage {
            fid: "synthetic-fid".to_string(),
            data,
            android_package_name: Some("dev.dokidango.firebase.messaging".to_string()),
            ttl_seconds: 60,
        };

        let request = SendRequest {
            message: SendMessage {
                fid: message.fid.as_str(),
                data: &message.data,
                android: AndroidConfig {
                    priority: "HIGH",
                    ttl: format!("{}s", message.ttl_seconds),
                    restricted_package_name: message.android_package_name.as_deref(),
                },
            },
        };

        let value = serde_json::to_value(request).expect("serialize request");
        assert_eq!(value["message"]["fid"], "synthetic-fid");
        assert_eq!(value["message"]["android"]["priority"], "HIGH");
        assert_eq!(value["message"]["android"]["ttl"], "60s");
        assert_eq!(
            value["message"]["android"]["restricted_package_name"],
            "dev.dokidango.firebase.messaging"
        );
        assert!(value["message"].get("token").is_none());
        assert!(value["message"].get("notification").is_none());
    }

    #[test]
    fn validates_data_payload_bounds_and_reserved_keys() {
        let mut data = BTreeMap::new();
        data.insert("kind".to_string(), "synthetic".to_string());
        let message = FcmDataMessage::new("synthetic-fid", data);
        validate_message(&message).expect("valid message");

        let mut oversized = BTreeMap::new();
        oversized.insert("payload".to_string(), "x".repeat(5000));
        let oversized_message = FcmDataMessage::new("synthetic-fid", oversized);
        assert!(matches!(
            validate_message(&oversized_message),
            Err(FcmSenderError::InvalidPayload(
                "serialized data payload exceeds 4096 bytes"
            ))
        ));

        for reserved in [
            "from",
            "message_type",
            "google.test",
            "gcm.notification.title",
        ] {
            let mut data = BTreeMap::new();
            data.insert(reserved.to_string(), "synthetic".to_string());
            let message = FcmDataMessage::new("synthetic-fid", data);
            assert!(matches!(
                validate_message(&message),
                Err(FcmSenderError::InvalidPayload(
                    "data payload contains an FCM-reserved key"
                ))
            ));
        }
    }

    #[test]
    fn retry_policy_matches_fcm_status_classes() {
        assert!(is_retryable_send_status(429));
        assert!(is_retryable_send_status(500));
        assert!(is_retryable_send_status(502));
        assert!(is_retryable_send_status(503));
        assert!(is_retryable_send_status(599));
        assert!(!is_retryable_send_status(400));
        assert!(!is_retryable_send_status(401));
        assert!(!is_retryable_send_status(403));
        assert!(!is_retryable_send_status(404));
    }
}
