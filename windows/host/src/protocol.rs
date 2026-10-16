use std::collections::BTreeMap;

use serde_json::Value;

use crate::fcm::FcmSenderError;

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Clone)]
pub struct ProtocolEnvelope {
    pub message_id: String,
    pub pair_id: String,
    pub kind: String,
    pub source_id: String,
    pub source_revision: u64,
    pub sent_at: String,
    pub expires_at: String,
    pub payload: Value,
    pub sender_seq: Option<u64>,
}

impl ProtocolEnvelope {
    pub fn to_fcm_data(&self) -> Result<BTreeMap<String, String>, FcmSenderError> {
        validate_nonempty("message_id", &self.message_id)?;
        validate_nonempty("pair_id", &self.pair_id)?;
        validate_nonempty("kind", &self.kind)?;
        validate_nonempty("source_id", &self.source_id)?;
        validate_nonempty("sent_at", &self.sent_at)?;
        validate_nonempty("expires_at", &self.expires_at)?;

        let mut data = BTreeMap::new();
        data.insert("protocol_version".to_string(), PROTOCOL_VERSION.to_string());
        data.insert("message_id".to_string(), self.message_id.clone());
        data.insert("pair_id".to_string(), self.pair_id.clone());
        data.insert("kind".to_string(), self.kind.clone());
        data.insert("source_id".to_string(), self.source_id.clone());
        data.insert(
            "source_revision".to_string(),
            self.source_revision.to_string(),
        );
        data.insert("sent_at".to_string(), self.sent_at.clone());
        data.insert("expires_at".to_string(), self.expires_at.clone());
        data.insert("payload".to_string(), serde_json::to_string(&self.payload)?);

        if let Some(sender_seq) = self.sender_seq {
            data.insert("sender_seq".to_string(), sender_seq.to_string());
        }

        Ok(data)
    }
}

fn validate_nonempty(field: &'static str, value: &str) -> Result<(), FcmSenderError> {
    if value.trim().is_empty() {
        return Err(FcmSenderError::InvalidPayload(field));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn envelope() -> ProtocolEnvelope {
        ProtocolEnvelope {
            message_id: "msg-1".to_string(),
            pair_id: "pair-1".to_string(),
            kind: "notification.upsert".to_string(),
            source_id: "source-1".to_string(),
            source_revision: 7,
            sent_at: "2026-10-15T00:00:00Z".to_string(),
            expires_at: "2026-10-15T00:01:00Z".to_string(),
            payload: serde_json::json!({"title":"synthetic"}),
            sender_seq: None,
        }
    }

    #[test]
    fn emits_required_p1_envelope_fields() {
        let data = envelope().to_fcm_data().expect("data");

        assert_eq!(data["protocol_version"], "1");
        assert_eq!(data["message_id"], "msg-1");
        assert_eq!(data["pair_id"], "pair-1");
        assert_eq!(data["kind"], "notification.upsert");
        assert_eq!(data["source_id"], "source-1");
        assert_eq!(data["source_revision"], "7");
        assert_eq!(data["sent_at"], "2026-10-15T00:00:00Z");
        assert_eq!(data["expires_at"], "2026-10-15T00:01:00Z");
        assert_eq!(data["payload"], r#"{"title":"synthetic"}"#);
        assert!(!data.contains_key("sender_seq"));
    }

    #[test]
    fn sender_seq_is_optional_and_diagnostics_only() {
        let mut value = envelope();
        value.sender_seq = Some(42);

        let data = value.to_fcm_data().expect("data");
        assert_eq!(data["sender_seq"], "42");
    }
}
