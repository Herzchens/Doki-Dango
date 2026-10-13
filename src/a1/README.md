# A1 Windows notification listener harness

This harness checks Windows `UserNotificationListener` behavior in two forms:

1. unpackaged .NET desktop process;
2. minimal full-trust MSIX package with the `userNotificationListener` capability.

It writes structured JSONL evidence under the current user's local application-data folder. Notification title/body text is written only when the source display name is explicitly allowlisted in the UI and the text contains the synthetic marker.

## Requirements

- Windows 10 or Windows 11;
- .NET 8 SDK;
- Windows 10/11 SDK containing MakeAppx and SignTool for the packaged path;
- Administrator rights only for trusting the local MSIX test certificate.

## Snapshot

From the repository root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\a1\Get-A1Snapshot.ps1
```

The snapshot records Windows edition/version/build/architecture/session, Git state, .NET information, and discovered Windows SDK packaging tools.

## A1.0 — unpackaged observation

Build:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\a1\Build-A1Unpackaged.ps1
```

Run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\a1\Run-A1Unpackaged.ps1
```

Use the buttons in order:

1. `Probe Current`;
2. `Request Access`;
3. `Poll`;
4. `Start Events`.

Record exceptions and HRESULTs exactly. An unpackaged result is a runtime observation only.

## Synthetic browser notification source

Start the local page:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\a1\Start-SyntheticNotificationPage.ps1
```

Open `http://127.0.0.1:8765/` in a browser, grant browser notification permission, and create a synthetic notification.

For privacy-safe readable-field evidence:

1. first poll with `Allowed text sources` empty;
2. note the browser source display name from metadata;
3. enter that exact source name in `Allowed text sources`;
4. copy the `DOKI-A1-...` marker from the page into `Synthetic marker prefix`;
5. create another synthetic notification and poll again.

Repeat with a second third-party notification source. A second browser is acceptable when Windows exposes it as a distinct source.

## A1.1 — minimal full MSIX

Build and sign the test package:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\a1\Build-A1Msix.ps1 -Architecture x64
```

Then open an elevated PowerShell in the repository root and install:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\a1\Install-A1Msix.ps1 -Architecture x64
```

Launch **Doki-Dango A1 Harness** from Start and repeat the core listener probes.

The package uses a local self-signed test certificate. Remove the package and certificate after the test:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\a1\Remove-A1Msix.ps1
```

## Evidence to return

Return:

- the snapshot JSON;
- unpackaged JSONL;
- packaged JSONL;
- any exact exception + HRESULT;
- the completed `src/a1/evidence/REPORT_TEMPLATE.md`.

Redact unrelated private data before sharing.
