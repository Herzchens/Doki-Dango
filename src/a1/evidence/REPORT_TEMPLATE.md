# A1 Windows notification listener evidence

## Environment

- Snapshot file:
- Branch:
- Commit:
- Windows edition:
- Windows version/build/UBR:
- Architecture:
- Session:
- .NET SDK:
- Windows SDK / MakeAppx:
- SignTool:

## A1.0 unpackaged

- `UserNotificationListener.Current`:
- `RequestAccessAsync()` result:
- Access status after request:
- `GetNotificationsAsync()`:
- `NotificationChanged`:
- Exception/HRESULT, if any:
- Evidence JSONL:

## A1.1 full MSIX

- Package install:
- Package full name:
- `UserNotificationListener.Current`:
- `RequestAccessAsync()` result:
- Access status after request:
- `GetNotificationsAsync()`:
- `NotificationChanged`:
- Exception/HRESULT, if any:
- Evidence JSONL:

## Core evidence

Use synthetic/test notification content only.

| Check | Result | Evidence |
| --- | --- | --- |
| Third-party source 1 |  |  |
| Third-party source 2 |  |  |
| Readable synthetic fields |  |  |
| Poll observes synthetic notification |  |  |
| Event observes add/remove |  |  |
| Restart behavior |  |  |
| Dismiss/update identity |  |  |
| Focus/DND |  |  |
| Locked/unlocked |  |  |
| Latency |  |  |
| Polling miss-window, if polling remains a candidate |  |  |
| CPU/resource, if polling remains a candidate |  |  |

## Reproducibility

- fresh_checkout:
- second_run_same_machine:
- Windows 10: `VERIFIED` / `UNVERIFIED`

## Redaction check

- No real notification title/body included:
- No tokens, credentials, or private payloads included:
- Non-test app/source names redacted if not relevant:
