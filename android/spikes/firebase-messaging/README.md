# Android runtime FCM harness

This Kotlin/Jetpack Compose harness validates runtime-configured Firebase Cloud Messaging without embedding `google-services.json`.

The `dev.dokidango.firebase.messaging` application ID is a test harness identity for the Firebase test project. It is not the production Doki-Dango Android application ID.

Coverage includes runtime Firebase options, registration, foreground/background/cold delivery, notification permission, reboot persistence, and APK replacement.
