# Android runtime FCM harness

This Kotlin/Jetpack Compose harness validates runtime-configured Firebase Cloud Messaging without embedding `google-services.json`.

The existing `dev.dokidango.bharness` application ID is a disposable compatibility identity for the current Firebase test project. It is not the production Doki-Dango Android application ID.

Coverage includes runtime Firebase options, registration, foreground/background/cold delivery, notification permission, reboot persistence, and APK replacement.
