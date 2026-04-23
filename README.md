# MFuse

[中文](README.zh-CN.md) | [Download](https://github.com/lollipopkit/mfuse/releases) | [License](LICENSE) | [Third-Party Notices](THIRD_PARTY_NOTICES.md)

> Warning
> This project is currently under active development. Behavior, APIs, and supported workflows may change.

MFuse is a macOS app that exposes remote storage in Finder through File Provider, with a modular backend layer for multiple protocols.

## Screenshots

<table>
  <tr>
    <td valign="top" width="28%">
      <img src="docs/pics/app.png" alt="MFuse app UI">
    </td>
    <td valign="top" width="32%">
      <img src="docs/pics/menubar.png" alt="MFuse menubar status">
    </td>
  </tr>
  <tr>
    <td colspan="2">
      <img src="docs/pics/finder.png" alt="MFuse mounted in Finder">
    </td>
  </tr>
</table>

## Supported Backends

- SFTP
- S3
- WebDAV
- SMB
- FTP
- NFS
- Google Drive
- Dropbox
- Microsoft OneDrive

## Backend Notes

- SFTP directory enumeration has a compatibility fallback: when the normal SFTP listing path times out or hits certain connection-level failures, MFuse may execute a small `python3` snippet on the remote host over the existing SSH session to enumerate the directory. This fallback is not used for normal successful listings, permission-denied errors, or missing-path errors. Remote hosts that hit this fallback must have `python3` available, otherwise enumeration fails.

## Project Structure

```text
.
├── MFuse/                  # macOS app
├── MFuseProvider/          # File Provider extension
├── Packages/
│   ├── MFuseCore/          # shared models, storage, mount abstractions
│   ├── MFuseSFTP/
│   ├── MFuseS3/
│   ├── MFuseWebDAV/
│   ├── MFuseSMB/
│   ├── MFuseFTP/
│   ├── MFuseNFS/
│   ├── MFuseGoogleDrive/
│   ├── MFuseDropbox/
│   └── MFuseOneDrive/
├── project.yml             # XcodeGen project definition
└── Makefile
```

## Getting Started

### Requirements

- macOS 14+
- Xcode 15+
- Swift 5.9+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `swiftlint` for linting

### Generate the Xcode project

```bash
make generate
```

### Configure bundled OAuth apps

Dropbox and OneDrive use bundled PKCE OAuth app settings loaded from build settings.
Set them in `project.local.yml` before running the app:

```yaml
settings:
  base:
    MFDROPBOX_CLIENT_ID: YOUR_DROPBOX_APP_KEY
    MFONEDRIVE_CLIENT_ID: YOUR_MICROSOFT_APP_ID
```

Default redirect URIs are already wired in the app bundle:

- Dropbox: `com.lollipopkit.mfuse.dropbox:/oauth`
- OneDrive: `com.lollipopkit.mfuse.onedrive:/oauth`

Current scope:

- Dropbox: standard user file space
- OneDrive: the signed-in user's default personal/work `drive`

Out of scope for this first pass:

- SharePoint document libraries and other non-default Microsoft Graph drives
- Dropbox Team Space / admin impersonation flows

### Run tests

```bash
make test
```

`make test` currently maps to `test-stable` and runs the stable local package subset.
Use `make test-all` when you want the full package test matrix.

### Lint

```bash
make lint
```

### Build

```bash
make build
```

### Release

```bash
make release
```

`make release` loads signing and notarization credentials from `.env`, computes the
current `git rev-list --count HEAD`, and releases with:

- `MARKETING_VERSION=<MFUSE_BASE_VERSION>.<commit count>`
- `CURRENT_PROJECT_VERSION=<commit count>`

Example: when the commit count is `2` and `MFUSE_BASE_VERSION=1.0`, the release
version becomes `1.0.2` and the build number becomes `2`.

The release flow now expects:

- a `Developer ID Application` certificate already installed in your macOS keychain
- notarization credentials already stored via `xcrun notarytool store-credentials`
- app and extension provisioning profiles already installed under `~/Library/MobileDevice/Provisioning Profiles`
- `gh` already authenticated for the target repository with upload permission

After notarization succeeds, `make release` automatically creates or updates the
GitHub Release tagged `v<MARKETING_VERSION>`, sets its title to the same value,
and uploads the generated DMG asset.

## Testing

Current test coverage is centered on Swift packages, especially:

- `MFuseCore` core models and connection management
- `MFuseFTP` parser behavior
- `MFuseWebDAV` XML parsing

Some backend tests are placeholders or integration-oriented, so protocol coverage is not uniform yet.

## License

MFuse is licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE).

Third-party dependencies remain under their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the current dependency notice summary.
