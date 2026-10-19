# ADR 0002: Windows Host/UI local IPC

**Status:** Accepted

## Context

The Windows Host is the authoritative long-running process. The Windows UI is a separate full-trust packaged process that must remain replaceable and must not own notification capture, credentials, or background lifecycle.

The process split already exists, but production UI work needs a local control boundary before any UI framework or product surface is added.

## Decision

The Windows Host owns a local named-pipe server at:

\`\\.\pipe\LOCAL\ItzHerzchen.DokiDango.HostUi.v1\`

The first IPC contract is deliberately narrow:

- protocol version: \`1\`
- encoding: UTF-8 JSON
- framing: one request and one response per pipe connection
- maximum request/response size: 4096 bytes
- initial request kind: \`host_status\`
- initial response state: \`running\`

The Host is always the server and source of truth. The UI is a client.

The pipe uses message mode, rejects remote clients, and uses an explicit protected DACL granting access to LocalSystem and the object owner. The default named-pipe security descriptor is not used.

The \`LOCAL\` namespace scopes the pipe to the current login session and is compatible with the packaged full-trust processes used by Doki-Dango.

Malformed JSON, unsupported IPC versions, unsupported request kinds, and oversized messages are rejected.

Host/UI IPC startup failure must not terminate or disable the notification Host. UI connection failure must not terminate the Host.

## Security boundary

This pipe is a same-session local transport boundary, not cryptographic client authentication.

Version 1 therefore exposes only read-only Host availability state. It does not expose:

- credentials or tokens
- notification private contents
- pairing secrets
- remote-control commands
- power or other dangerous actions
- arbitrary filesystem or process operations

Before private data or mutating operations are added, caller authorization and channel-authentication requirements must receive a new security review and this ADR must be amended or superseded.

The pipe name is not treated as a secret.

## Alternatives considered

### App services

App services provide packaged application IPC but introduce additional activation/background-service lifecycle semantics that are unnecessary for two full-trust processes already sharing one MSIX package.

### COM or RPC

COM/RPC can provide richer interfaces and identity controls, but adds substantially more registration, lifetime, and compatibility surface than required for the first local status contract.

### Loopback TCP

Loopback networking creates an unnecessary socket/listener surface and firewall/network semantics for same-machine process communication.

### Files or registry polling

Filesystem or registry exchange does not provide a clean request/response boundary, adds race and cleanup behavior, and is unsuitable for future interactive UI operations.

## Consequences

The IPC contract is explicitly versioned independently from the cross-device notification protocol.

The Windows platform crate owns the transport because it is Windows-specific. The Host owns server lifecycle. The UI consumes the client API.

The initial contract proves the process boundary without selecting a production UI framework.

Future operations must remain capability-scoped and must not move Host-owned state into the UI process.

## References

- Microsoft Learn: Interprocess communication for Windows apps
- Microsoft Learn: Named Pipe Security and Access Rights
- Microsoft Learn: CreateNamedPipe
