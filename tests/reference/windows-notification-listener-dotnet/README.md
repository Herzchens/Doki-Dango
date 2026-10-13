# Windows notification listener reference

This .NET desktop harness is retained as a reference implementation for the Windows `UserNotificationListener` surface used by Doki-Dango.

It is test-only. Production Windows Host work is implemented in Rust.

Coverage includes packaged identity, notification access, polling, `NotificationChanged`, synthetic source metadata, title/body capture, replacement behavior, and removal observations.
