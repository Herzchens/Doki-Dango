# Windows packaging

`Build-Package.ps1` creates the unsigned MSIX for the Windows Host.

For local runtime validation only:

1. run `Build-Package.ps1`;
2. run `Sign-DevelopmentPackage.ps1`;
3. run `Install-DevelopmentPackage.ps1` from an elevated PowerShell.

The development signer uses the production package publisher subject (`CN=ItzHerzchen`) so the package identity remains stable, but the self-signed certificate is not a production trust strategy and must not be published as a release credential.

## Release integrity

Release integrity metadata can be prepared without selecting the production signing provider:

- `scripts/release/windows/New-ReleaseIntegrity.ps1` records the package SHA-256, stable package identity, source commit, and factual Authenticode signer information.
- `scripts/release/windows/New-CargoSpdxSbom.ps1` generates an SPDX 2.3 dependency inventory from locked Cargo metadata.
- `scripts/release/windows/Test-ReleaseCandidate.ps1` is the publication trust gate. It requires an explicitly approved signer thumbprint, rejects the known development signer, and verifies the artifact hash, source commit, package identity, and SBOM.

The release trust gate is intentionally not wired to a production release workflow until the public Windows signing strategy is approved. Development-signed artifacts must never be published as production releases.


## Upgrade and recovery validation

The package build script accepts an optional four-part `-PackageVersion` and custom `-OutputPath` for isolated upgrade-path testing. These options modify only the staged manifest; the tracked `AppxManifest.xml` remains unchanged.

`Test-VersionedPackageBuild.ps1` is non-destructive and validates versioned MSIX identity continuity in CI.

`Test-PackageUpgradeRecovery.ps1` is an explicit elevated runtime test. It registers temporary development-signed versions, verifies a normal forward upgrade, verifies rollback with Windows `ForceUpdateFromAnyVersion`, checks package-family continuity and synthetic external Host state preservation, then restores the prior registered package version when one existed. It does not implement or authorize an auto-updater.
