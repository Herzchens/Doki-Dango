use std::{error::Error as StdError, fmt};

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ProtocolEnvelope {
    pub protocol_version: u32,
    pub message_id: String,
    pub pair_id: String,
    pub kind: String,
    pub source_id: String,
    pub source_revision: u64,
    pub sent_at: String,
    pub expires_at: String,
    pub payload: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sender_seq: Option<u64>,
}

#[derive(Debug)]
pub enum ProtocolError {
    Json(serde_json::Error),
    UnsupportedVersion(u32),
    EmptyField(&'static str),
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Json(error) => write!(formatter, "protocol JSON decode failed: {error}"),
            Self::UnsupportedVersion(version) => {
                write!(formatter, "unsupported protocol version: {version}")
            }
            Self::EmptyField(field) => {
                write!(formatter, "required protocol field is empty: {field}")
            }
        }
    }
}

impl StdError for ProtocolError {
    fn source(&self) -> Option<&(dyn StdError + 'static)> {
        match self {
            Self::Json(error) => Some(error),
            _ => None,
        }
    }
}

impl From<serde_json::Error> for ProtocolError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

impl ProtocolEnvelope {
    #[allow(clippy::too_many_arguments)]
    pub fn v1(
        message_id: impl Into<String>,
        pair_id: impl Into<String>,
        kind: impl Into<String>,
        source_id: impl Into<String>,
        source_revision: u64,
        sent_at: impl Into<String>,
        expires_at: impl Into<String>,
        payload: Value,
        sender_seq: Option<u64>,
    ) -> Result<Self, ProtocolError> {
        let envelope = Self {
            protocol_version: PROTOCOL_VERSION,
            message_id: message_id.into(),
            pair_id: pair_id.into(),
            kind: kind.into(),
            source_id: source_id.into(),
            source_revision,
            sent_at: sent_at.into(),
            expires_at: expires_at.into(),
            payload,
            sender_seq,
        };
        envelope.validate()?;
        Ok(envelope)
    }

    pub fn from_json_str(json: &str) -> Result<Self, ProtocolError> {
        let envelope: Self = serde_json::from_str(json)?;
        envelope.validate()?;
        Ok(envelope)
    }

    pub fn from_json_value(value: Value) -> Result<Self, ProtocolError> {
        let envelope: Self = serde_json::from_value(value)?;
        envelope.validate()?;
        Ok(envelope)
    }

    pub fn validate(&self) -> Result<(), ProtocolError> {
        if self.protocol_version != PROTOCOL_VERSION {
            return Err(ProtocolError::UnsupportedVersion(self.protocol_version));
        }
        validate_nonempty("message_id", &self.message_id)?;
        validate_nonempty("pair_id", &self.pair_id)?;
        validate_nonempty("kind", &self.kind)?;
        validate_nonempty("source_id", &self.source_id)?;
        validate_nonempty("sent_at", &self.sent_at)?;
        validate_nonempty("expires_at", &self.expires_at)?;
        Ok(())
    }
}

fn validate_nonempty(field: &'static str, value: &str) -> Result<(), ProtocolError> {
    if value.trim().is_empty() {
        return Err(ProtocolError::EmptyField(field));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Deserialize)]
    struct FixtureCase {
        name: String,
        valid: bool,
        envelope: Value,
    }

    #[test]
    fn validates_canonical_v1_fixtures() {
        let fixture_data = include_str!("../fixtures/v1.json");
        let cases: Vec<FixtureCase> =
            serde_json::from_str(fixture_data).expect("parse fixtures/v1.json");

        assert!(
            cases.len() >= 20,
            "expected at least 20 fixture cases, found {}",
            cases.len()
        );

        for case in cases {
            let result = ProtocolEnvelope::from_json_value(case.envelope.clone());
            if case.valid {
                assert!(
                    result.is_ok(),
                    "fixture case '{}' was expected to be valid, but failed: {:?}",
                    case.name,
                    result.err()
                );
                let env = result.unwrap();
                assert_eq!(env.protocol_version, 1);
            } else {
                assert!(
                    result.is_err(),
                    "fixture case '{}' was expected to be invalid, but succeeded: {:?}",
                    case.name,
                    result.ok()
                );
            }
        }
    }

    #[test]
    fn constructor_v1_creates_valid_envelope() {
        let env = ProtocolEnvelope::v1(
            "msg-test",
            "pair-test",
            "notification.upsert",
            "src-test",
            10,
            "2026-10-18T12:00:00Z",
            "2026-10-18T12:05:00Z",
            serde_json::json!({"test": true}),
            Some(99),
        )
        .expect("valid envelope");

        assert_eq!(env.protocol_version, 1);
        assert_eq!(env.message_id, "msg-test");
        assert_eq!(env.sender_seq, Some(99));
    }

    #[test]
    fn constructor_v1_rejects_empty_fields() {
        let result = ProtocolEnvelope::v1(
            "   ",
            "pair-test",
            "notification.upsert",
            "src-test",
            10,
            "2026-10-18T12:00:00Z",
            "2026-10-18T12:05:00Z",
            serde_json::json!({}),
            None,
        );

        assert!(result.is_err());
        match result.unwrap_err() {
            ProtocolError::EmptyField(field) => assert_eq!(field, "message_id"),
            other => panic!("unexpected error: {other:?}"),
        }
    }
}
