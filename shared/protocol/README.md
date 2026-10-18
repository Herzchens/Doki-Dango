# Doki-Dango Shared Protocol

This directory contains the language-neutral logical protocol contract for Doki-Dango notification mirroring, along with the canonical golden test fixtures and the Rust reference model.

The canonical cross-platform contract is defined by:
1. This language-neutral specification document.
2. The shared golden JSON fixtures in [`fixtures/v1.json`](fixtures/v1.json).

Platform language implementations (Rust and Kotlin) validate and conform to this single source of truth.

---

## Protocol Version 1

Doki-Dango protocol version 1 defines a logical envelope for mirrored notifications exchanged between paired endpoints.

### Fields and Types

| Field | Type | Required | Description |
| :--- | :--- | :--- | :--- |
| `protocol_version` | Unsigned Integer | Yes | Must be `1` for Protocol v1. |
| `message_id` | Non-empty String | Yes | Unique identifier for this message envelope. |
| `pair_id` | Non-empty String | Yes | Identifier of the authenticated pairing session. |
| `kind` | Non-empty String | Yes | Message classification (e.g., `notification.upsert`). |
| `source_id` | Non-empty String | Yes | Unique identifier of the notification source device/subsystem. |
| `source_revision`| Unsigned 64-bit Integer | Yes | Monotonically increasing revision number for the source state. |
| `sent_at` | Non-empty String | Yes | Intended ISO 8601 UTC timestamp of message transmission (validated as non-empty string in v1). |
| `expires_at` | Non-empty String | Yes | Intended ISO 8601 UTC timestamp after which the message must be discarded (validated as non-empty string in v1). |
| `payload` | Valid JSON Value | Yes | Arbitrary structured notification payload (object, array, primitive). |
| `sender_seq` | Unsigned 64-bit Integer | No | Optional monotonically increasing sequence assigned by the sender. |

---

## Validation Rules

1. **Version Enforcement**:
   - `protocol_version == 1` is strictly required.
   - Any unsupported or future version must be rejected.
2. **Required Fields**:
   - All nine required fields must be present.
   - Missing required fields must result in rejection.
3. **Type Strictness**:
   - Fields must match their declared JSON data types.
   - Mismatched types (e.g., string in place of integer) must be rejected.
4. **String Content and Timestamps**:
   - Required string fields (`message_id`, `pair_id`, `kind`, `source_id`, `sent_at`, `expires_at`) cannot be empty or consist solely of whitespace characters.
   - For `sent_at` and `expires_at`, ISO 8601 UTC (e.g., `2026-10-18T10:00:00Z`) is the canonical semantic representation. In Protocol v1, boundary validation enforces non-empty, non-whitespace strings; strict ISO 8601 parsing may be enforced in future protocol revisions.
5. **Optional Sequence (`sender_seq`)**:
   - When omitted, the envelope is valid.
   - When present, it must be an unsigned 64-bit integer.
   - Explicit `null` value is invalid; callers must omit the field entirely when absent.
6. **Forward Compatibility (Unknown Fields)**:
   - For a supported protocol version, any unexpected extra fields must be safely tolerated and ignored by receivers.

---

## Separation from Transport Adapters

The shared protocol envelope model is purely transport-neutral and logical.

- **FCM String-Map Encoding**:
  - Firebase Cloud Messaging (FCM) requires key-value data payloads to be encoded as flat string mappings (`Map<String, String>`).
  - This transport-specific encoding (string serialization of scalar fields, compact JSON serialization of `payload`) is implemented strictly inside platform transport adapters (e.g., Windows Host FCM sender) and is **not** part of the logical protocol specification.
- **Transport Limits**:
  - Provider limits such as the FCM 4096-byte payload cap, OAuth 2.0 authorization tokens, Firebase Installation IDs (FIDs), and TTL headers are transport-layer concerns outside this contract.
- **Test Instrumentation Markers**:
  - Integration test markers such as `doki_test_id` are harness-level metadata used by QA receivers to verify end-to-end receipt. They are distinct from and must never be conflated with the canonical protocol envelope.

---

## Canonical Golden Fixtures

All implementations must validate against [`fixtures/v1.json`](fixtures/v1.json).

The fixture file contains named positive and negative test cases:
- **Valid vectors**: Minimal envelopes, envelopes with optional sequence numbers, envelopes with nested complex payloads, and envelopes containing unknown future fields.
- **Invalid vectors**: Envelopes with missing fields, unsupported versions, empty or whitespace strings, and invalid data types.
