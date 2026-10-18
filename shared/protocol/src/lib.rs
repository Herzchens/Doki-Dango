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
    #[serde(
        default,
        deserialize_with = "deserialize_sender_seq",
        skip_serializing_if = "Option::is_none"
    )]
    pub sender_seq: Option<u64>,
}

fn deserialize_sender_seq<'de, D>(deserializer: D) -> Result<Option<u64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    struct SenderSeqVisitor;

    impl<'de> serde::de::Visitor<'de> for SenderSeqVisitor {
        type Value = Option<u64>;

        fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
            formatter.write_str("an unsigned 64-bit integer")
        }

        fn visit_u64<E>(self, v: u64) -> Result<Self::Value, E>
        where
            E: serde::de::Error,
        {
            Ok(Some(v))
        }

        fn visit_u128<E>(self, v: u128) -> Result<Self::Value, E>
        where
            E: serde::de::Error,
        {
            if v <= u64::MAX as u128 {
                Ok(Some(v as u64))
            } else {
                Err(E::custom("sender_seq overflow"))
            }
        }

        fn visit_i64<E>(self, v: i64) -> Result<Self::Value, E>
        where
            E: serde::de::Error,
        {
            if v >= 0 {
                Ok(Some(v as u64))
            } else {
                Err(E::custom("sender_seq cannot be negative"))
            }
        }

        fn visit_unit<E>(self) -> Result<Self::Value, E>
        where
            E: serde::de::Error,
        {
            Err(E::custom(
                "sender_seq cannot be null; omit the field if absent",
            ))
        }

        fn visit_none<E>(self) -> Result<Self::Value, E>
        where
            E: serde::de::Error,
        {
            Err(E::custom(
                "sender_seq cannot be null; omit the field if absent",
            ))
        }
    }

    deserializer.deserialize_u64(SenderSeqVisitor)
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

    #[test]
    fn boundary_accepts_u64_max() {
        let json = r#"{
            "protocol_version": 1,
            "message_id": "msg-max",
            "pair_id": "pair-1",
            "kind": "notification.upsert",
            "source_id": "source-1",
            "source_revision": 18446744073709551615,
            "sent_at": "2026-10-18T10:00:00Z",
            "expires_at": "2026-10-18T10:05:00Z",
            "payload": {},
            "sender_seq": 18446744073709551615
        }"#;

        let env = ProtocolEnvelope::from_json_str(json).expect("valid u64::MAX");
        assert_eq!(env.source_revision, u64::MAX);
        assert_eq!(env.sender_seq, Some(u64::MAX));
    }

    #[test]
    fn boundary_rejects_u64_overflow() {
        let json_rev = r#"{
            "protocol_version": 1,
            "message_id": "msg-ovf",
            "pair_id": "pair-1",
            "kind": "notification.upsert",
            "source_id": "source-1",
            "source_revision": 18446744073709551616,
            "sent_at": "2026-10-18T10:00:00Z",
            "expires_at": "2026-10-18T10:05:00Z",
            "payload": {}
        }"#;
        assert!(ProtocolEnvelope::from_json_str(json_rev).is_err());

        let json_seq = r#"{
            "protocol_version": 1,
            "message_id": "msg-ovf",
            "pair_id": "pair-1",
            "kind": "notification.upsert",
            "source_id": "source-1",
            "source_revision": 1,
            "sent_at": "2026-10-18T10:00:00Z",
            "expires_at": "2026-10-18T10:05:00Z",
            "payload": {},
            "sender_seq": 18446744073709551616
        }"#;
        assert!(ProtocolEnvelope::from_json_str(json_seq).is_err());
    }

    #[test]
    fn boundary_rejects_explicit_null_sender_seq() {
        let json = r#"{
            "protocol_version": 1,
            "message_id": "msg-null",
            "pair_id": "pair-1",
            "kind": "notification.upsert",
            "source_id": "source-1",
            "source_revision": 1,
            "sent_at": "2026-10-18T10:00:00Z",
            "expires_at": "2026-10-18T10:05:00Z",
            "payload": {},
            "sender_seq": null
        }"#;
        assert!(ProtocolEnvelope::from_json_str(json).is_err());
    }

    #[test]
    fn boundary_rejects_fractional_numbers() {
        let json_ver = r#"{
            "protocol_version": 1.5,
            "message_id": "msg-frac",
            "pair_id": "pair-1",
            "kind": "notification.upsert",
            "source_id": "source-1",
            "source_revision": 1,
            "sent_at": "2026-10-18T10:00:00Z",
            "expires_at": "2026-10-18T10:05:00Z",
            "payload": {}
        }"#;
        assert!(ProtocolEnvelope::from_json_str(json_ver).is_err());

        let json_rev = r#"{
            "protocol_version": 1,
            "message_id": "msg-frac",
            "pair_id": "pair-1",
            "kind": "notification.upsert",
            "source_id": "source-1",
            "source_revision": 1.5,
            "sent_at": "2026-10-18T10:00:00Z",
            "expires_at": "2026-10-18T10:05:00Z",
            "payload": {}
        }"#;
        assert!(ProtocolEnvelope::from_json_str(json_rev).is_err());

        let json_seq = r#"{
            "protocol_version": 1,
            "message_id": "msg-frac",
            "pair_id": "pair-1",
            "kind": "notification.upsert",
            "source_id": "source-1",
            "source_revision": 1,
            "sent_at": "2026-10-18T10:00:00Z",
            "expires_at": "2026-10-18T10:05:00Z",
            "payload": {},
            "sender_seq": 1.5
        }"#;
        assert!(ProtocolEnvelope::from_json_str(json_seq).is_err());
    }
}
