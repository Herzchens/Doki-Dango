# Windows packaging

`Build-Package.ps1` creates the unsigned MSIX for the Windows Host.

For local runtime validation only:

1. run `Build-Package.ps1`;
2. run `Sign-DevelopmentPackage.ps1`;
3. run `Install-DevelopmentPackage.ps1` from an elevated PowerShell.

The development signer uses the production package publisher subject (`CN=ItzHerzchen`) so the package identity remains stable, but the self-signed certificate is not a production trust strategy and must not be published as a release credential.
