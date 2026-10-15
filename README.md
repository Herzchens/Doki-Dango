# Doki-Dango

Cross-device notification synchronization and remote action platform connecting desktop and mobile environments.

## Status

Doki-Dango is under active pre-production development. Engineering foundations are established for the Windows Host background runtime, credential protection, notification capture, FCM delivery, diagnostics, release integrity verification, and package upgrade recovery tooling.

This repository represents pre-release engineering and infrastructure foundations rather than a finished end-user product:
- A production desktop UI has not been implemented yet.
- The production Android application and user interface have not been implemented yet.
- Release-integrity and package-recovery tooling serve as engineering verification and preflight foundations, not an indicator of general release readiness.

## Platforms

- **Windows**: Authoritative Host background runtime, DPAPI credential protection, native WinRT notification capture, background lifecycle management, diagnostics, and packaged MSIX distribution. The `doki-dango-ui` executable is currently only a process-boundary bootstrap scaffold; a production desktop UI is not yet implemented.
- **Android**: Prototype Firebase Cloud Messaging receiver and notification action delivery harness. A production Android application and user interface are not yet implemented.

## Repository Entrypoints

- `apps/host` — Windows Host authoritative process (`doki-dango-host`).
- `apps/ui` — Windows UI process-boundary bootstrap scaffold (`doki-dango-ui`).
- `crates/platform-windows` — Windows platform abstractions, WinRT listener, and DPAPI credential protection.
- `packaging/windows` — Windows MSIX packaging assets and configuration.
- `scripts/package/windows` — Windows package build and signing scripts.
- `scripts/release/windows` — Release integrity and SBOM generation tooling.
- `scripts/test/windows-host` — Platform and integration verification scripts.

## Security

To report security vulnerabilities, please use [GitHub Private Vulnerability Reporting](https://github.com/Herzchens/Doki-Dango/security/advisories/new) or contact the maintainers directly. Do not report security vulnerabilities through public issues.

## License

This project is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.
