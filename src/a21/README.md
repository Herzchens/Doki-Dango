# A2.1 Rust parity harness

A2.1 replaces only the selected A1 Windows listener path with Rust. It does not add Android transport, pairing, relay, credentials, production UI, or service architecture.

The implementation uses Microsoft `windows` crate `0.62.2` and the same supported WinRT surface as A1:

- `UserNotificationListener.Current`
- access status / `RequestAccessAsync`
- `GetNotificationsAsync(NotificationKinds::Toast)`
- `NotificationChanged`
- `GetNotification`
- `ToastGeneric` text extraction for explicitly allowed synthetic sources

The disposable MSIX declares the same `userNotificationListener` and `runFullTrust` capabilities as A1.

Evidence is written to:

```text
%LOCALAPPDATA%\Doki-Dango\A21\evidence\a21-*.jsonl
```

Text is inspected only for the synthetic Brave and Google Chrome source names. Other notification sources are metadata-only.

The parity fixture at `tools/a21/synthetic-notification/index.html` can create a new notification, replace the current browser tag with new synthetic content, and close the current notification object. Manual dismissal in Windows notification UI should also be characterized separately.

A2.1 PASS requires same selected listener behavior, equivalent source/field capture, equivalent update/dismiss observations, and a successful second run after restarting the packaged Rust harness.
