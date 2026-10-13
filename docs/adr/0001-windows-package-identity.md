# ADR 0001: Windows package identity

**Status:** Accepted

## Decision

The Windows Host uses the following stable package identity:

- Package name: `ItzHerzchen.DokiDango`
- Publisher: `CN=ItzHerzchen`
- Application ID: `Host`
- Executable: `dokidango.exe`
- Display name: `Doki-Dango`
- Publisher display name: `ItzHerzchen`

Development packages may be signed with a local self-signed certificate whose subject is exactly `CN=ItzHerzchen`. Development signing is for local validation only and is not a production release trust strategy.

## Consequences

The package and publisher identity are treated as stable because changing them can break package-family continuity and upgrades. Public release signing remains a separate security gate.
