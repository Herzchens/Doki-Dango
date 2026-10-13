# Rust Windows notification listener harness

This packaged Rust harness validates the Windows notification listener path selected for the Doki-Dango Host.

It uses Microsoft's `windows` crate against the same WinRT surface as the .NET reference harness: listener access, polling, `NotificationChanged`, notification lookup, synthetic source metadata, replacement behavior, and removal observations.

The harness remains under `tests/` because it is verification infrastructure, not the production Host executable.
