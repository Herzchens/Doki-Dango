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

- `windows/host` — Windows Host authoritative process (`doki-dango-host`).
- `windows/ui` — Windows UI process-boundary bootstrap scaffold (`doki-dango-ui`).
- `windows/platform` — Windows platform abstractions, WinRT listener, and DPAPI credential protection.
- `windows/packaging` — Windows MSIX packaging assets and configuration.
- `windows/scripts/package` — Windows package build and signing scripts.
- `windows/scripts/release` — Release integrity and SBOM generation tooling.
- `windows/tests/host` — Platform and host verification scripts.
- `windows/tests/packaging` — Package upgrade and release integrity verification scripts.

## Security

To report security vulnerabilities, please use [GitHub Private Vulnerability Reporting](https://github.com/Herzchens/Doki-Dango/security/advisories/new) or contact the maintainers directly. Do not report security vulnerabilities through public issues.

## License

This project is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.
