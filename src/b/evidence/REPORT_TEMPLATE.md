# B runtime BYO-FCM evidence

## Environment

- Branch:
- Commit:
- Android device/model:
- Android version/API:
- Google Play Services version:
- Firebase Messaging SDK: `26.0.0`
- APK package: `dev.dokidango.bharness` (disposable spike identity)

## Gate 1 — runtime bootstrap

- No embedded `google-services.json`:
- Runtime FirebaseOptions persisted:
- DEFAULT FirebaseApp initialized from persisted options:
- `register()` task:
- `onRegistered(fid)` callback:
- FID fingerprint only:
- Foreground data-only send accepted by FCM:
- `onMessageReceived()` observed:
- Local synthetic notification posted:
- Result: `PASS` / `NO-GO` / `INCONCLUSIVE`

## Gate 2 — cold process

- Process confirmed absent before send:
- Send accepted by FCM:
- Doki callback executed after cold start:
- Local synthetic notification posted:
- Initialization-order workaround required:
- Result: `PASS` / `NO-GO` / `INCONCLUSIVE`

## Remaining matrix

| Check | Result | Evidence |
| --- | --- | --- |
| no config |  |  |
| incomplete config |  |  |
| wrong app ID |  |  |
| wrong project |  |  |
| wrong API key |  |  |
| broken API restriction |  |  |
| wrong package |  |  |
| SHA-1 omitted |  |  |
| foreground |  |  |
| background |  |  |
| reboot |  |  |
| pre-first-unlock characterization |  |  |
| process restart |  |  |
| APK update |  |  |
| Play Services restart, if reproducible |  |  |
| FID persistence/change |  |  |
| wipe/reinstall recovery |  |  |
| POST_NOTIFICATIONS |  |  |
| notification channel readiness |  |  |
| API restriction/effects |  |  |

## Reproducibility

- fresh_checkout:
- second_run_same_device:
- second device/OEM: `VERIFIED` / `UNVERIFIED`

## Redaction check

- No raw FID included:
- No OAuth token included:
- No service-account private key included:
- No private/non-test payload included:

## Classification

- Technical: `PASS` / `PASS WITH PRODUCT RISK` / `FAIL` / `INCONCLUSIVE`
- Product onboarding burden:
- Deferred/manual follow-up:
