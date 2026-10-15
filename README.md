# Doki-Dango

Cross-device notification synchronization and remote action platform connecting desktop and mobile environments.

## Status

Doki-Dango is currently under active development. Core background execution, credential protection, production FCM delivery, release integrity verification, and package upgrade recovery workflows are implemented and verified.

## Platforms

- **Windows**: Authoritative Host background runtime, credential protection via DPAPI, native WinRT notification listener, thin presentation UI client, and packaged MSIX distribution.
- **Android**: Firebase Cloud Messaging receiver and notification action client (prototype).

## Repository Entrypoints

- `apps/host` — Windows Host authoritative process (`doki-dango-host`).
- `apps/ui` — Windows UI presentation client (`doki-dango-ui`).
- `crates/platform-windows` — Windows platform abstractions, WinRT listener, and DPAPI credential protection.
- `packaging/windows` — Windows MSIX packaging assets and configuration.
- `scripts/package/windows` — Windows package build and signing scripts.
- `scripts/release/windows` — Release integrity and SBOM generation tooling.
- `scripts/test/windows-host` — Platform and integration verification scripts.

## Security

To report security vulnerabilities, please use [GitHub Private Vulnerability Reporting](https://github.com/Herzchens/Doki-Dango/security/advisories/new) or contact the maintainers directly. Do not report security vulnerabilities through public issues.

## License

This project is licensed under the Apache License, Version 2.0. See the [LICENSE](LICENSE) file for details.
