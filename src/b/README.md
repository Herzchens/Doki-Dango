# B runtime BYO-FCM feasibility harness

This spike tests whether a generic Android APK can use Firebase Cloud Messaging without an embedded `google-services.json` file.

The Android package ID used here is **`dev.dokidango.bharness`**. It is a disposable spike identity only and is not Doki-Dango's production application ID.

## Pinned tooling

- Android implementation: Kotlin
- UI: minimal Jetpack Compose
- Firebase Messaging: `26.0.0`
- Android Gradle Plugin: `9.0.1`
- built-in Kotlin from AGP: KGP `2.2.10`
- Compose compiler plugin: `2.2.10`
- Compose BOM: `2026.04.01`
- AndroidX Activity Compose: `1.13.0`
- Gradle: `9.1.0`
- compile SDK: Android `36.1`
- minimum Android API for this spike: `24`
- JVM target: `17`

AGP 9 provides built-in Kotlin support, so the project intentionally does not apply `org.jetbrains.kotlin.android`. The Compose compiler plugin is pinned to the same Kotlin version supplied by AGP.

The Compose BOM is intentionally pinned to the April 2026 line so this spike stays compatible with the already-installed Android 36.1 SDK rather than forcing a compileSdk 37 toolchain change.

Firebase Messaging `26.0.0` declares minSdk 24, so the disposable B harness uses API 24 as its minimum. This is a spike constraint and does not set Doki-Dango's eventual production Android support floor.

The build script downloads only the pinned Gradle binary distribution and verifies its SHA-256 before use. Android SDK components are not installed or modified by the script.

## Build

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\b\Build-BAndroid.ps1
```

The APK is copied to:

```text
artifacts\b\package\DokiDango.BHarness-debug.apk
```

## Runtime configuration model

The APK intentionally has no Google Services Gradle plugin and no embedded Firebase config file.

The Compose UI accepts and persists the three Firebase options required by this spike:

- Firebase project ID;
- Firebase Android App ID (`mobilesdk_app_id`);
- Firebase API key.

The custom `Application` loads the persisted options at process start and initializes the **DEFAULT** `FirebaseApp`. This is the path that must also work when the process is started by FCM rather than by the Activity.

The app disables FCM auto-initialization (and analytics collection metadata) and exposes an explicit **Register with FCM** action. The manifest enables FID-based FCM registration. `onRegistered()` stores the raw FID only in app-private storage and records only a short SHA-256 fingerprint in JSONL evidence.

## Install

With one authorized Android device connected:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\b\Install-BAndroid.ps1
```

In the app:

1. enter runtime Firebase options;
2. save them;
3. initialize the DEFAULT `FirebaseApp`;
4. request notification permission when required;
5. register with FCM.

A received test callback counts as delivery evidence only when the harness also records `local_notification = posted`; missing `POST_NOTIFICATIONS` permission is recorded as blocked rather than a false visible-notification PASS.

After `onRegistered()` has fired, capture the FID into a local secret file without printing it:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\b\Capture-BFid.ps1
```

The raw FID is stored outside the repository under `%LOCALAPPDATA%\Doki-Dango\B\secrets`.

## OAuth access token

For local testing, create a short-lived Firebase Messaging OAuth access token from a service-account JSON kept outside the repository. Use PowerShell 7:

```powershell
pwsh.exe -NoProfile -File .\scripts\b\New-BAccessToken.ps1 -ServiceAccountJson <path-outside-repo>
```

The script never prints the token and stores it under `%LOCALAPPDATA%\Doki-Dango\B\secrets`.

Do not copy service-account JSON, FIDs, or access tokens into the repository or QA evidence bundles.

## Data-only HTTP v1 send

Send a unique high-priority data-only test message targeted by FID:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\b\Send-BTestMessage.ps1 -ProjectId <firebase-project-id>
```

The Android callback accepts only payloads with a `doki_test_id` beginning with `DOKI-B-`. It records the callback and then posts a local synthetic notification. No notification payload is used to prove cold/background callback execution.

## Evidence

Export app evidence with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\b\Export-BEvidence.ps1
```

The app evidence intentionally does not contain:

- raw FID;
- OAuth access token;
- service-account private key;
- Firebase API key;
- arbitrary message payloads.

The runtime tests remain device-scoped. Until a physical Android device is available, build/static verification can proceed but B runtime gates stay `UNVERIFIED`.
