# A2.0 end-to-end tracer

This is a disposable tracer for the A2.0 gate. It is not production implementation.

It connects only already-proven pieces:

```text
synthetic Windows notification
→ packaged A1 NotificationChanged listener
→ minimal PowerShell glue
→ proven B HTTP-v1 sender
→ Android FirebaseMessagingService callback
→ Doki local notification
```

A2.0 intentionally does **not** add Rust, production pairing, DPAPI, relay/provider abstractions, production UI, metrics, updater work, or agent controls.

## Preconditions

- A1 packaged MSIX harness is installed and running.
- A1 has notification access.
- **Start Events** has succeeded in the current A1 evidence file.
- The A1 synthetic filter allows the browser source used for the test (for example Brave or Chrome).
- The Android B harness is installed, configured, registered, and has notification permission.
- `%LOCALAPPDATA%\Doki-Dango\B\secrets\fid.txt` exists.
- `%LOCALAPPDATA%\Doki-Dango\B\secrets\access-token.json` contains a non-expired short-lived OAuth token.

Refresh the B OAuth token immediately before an A2.0 run when needed.

## Run

Start the packaged A1 harness and click **Start Events** first. Then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\a2\Start-A20Tracer.ps1 -ProjectId <firebase-project-id>
```

Then create one NEW notification with the existing A1 synthetic browser page.

The tracer ignores old A1 events. It waits for a new `notification_event_snapshot` with a timestamped `DOKI-A1-` marker, derives a unique `DOKI-B-A20-` test ID, sends it through the proven B HTTP-v1 sender, and waits for the matching Android callback and local notification.

Evidence is written under:

```text
artifacts\a2\evidence\
```

The A2 evidence contains synthetic identifiers and timestamps only. It must not contain raw FID, OAuth tokens, API keys, service-account keys, or private notification content.

## PASS

A2.0 requires **two** successful end-to-end runs.

Each run must have timestamps for:

- Windows synthetic source created;
- packaged A1 listener observed;
- FCM accepted;
- Android callback;
- local notification posted.

Before the second run, restart the relevant tracer components:

- close and reopen the packaged A1 harness;
- start its event listener again;
- stop and restart `Start-A20Tracer.ps1`.

The Android app may remain installed/configured. Do not force-stop it for A2.0 unless a separate test specifically requires that behavior.

After two successful runs, A2.0 can close and A2.1 Rust parity may begin.
