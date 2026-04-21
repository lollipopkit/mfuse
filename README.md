# MFuse

[中文说明](README.zh-CN.md) | [License](LICENSE) | [Third-Party Notices](THIRD_PARTY_NOTICES.md)

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
│   └── MFuseGoogleDrive/
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

### Local Xcode builds

If you build `MFuse.app` from Xcode and copy it into `/Applications`, use a valid Apple development team for both the app target and the File Provider extension target.

Do not rely on changing the generated Xcode project by hand. `MFuse.xcodeproj` is regenerated from `project.yml`, so manual signing edits in Xcode can be lost the next time you run `make generate`.

For stable local signing, copy `project.local.example.yml` to `project.local.yml`, fill in the signing values that match your local setup, and regenerate the project. `project.local.yml` is ignored by Git and is automatically merged by `make generate`.

`project.local.example.yml` now covers both local override paths:

- inject only `DEVELOPMENT_TEAM` and keep Automatic signing
- pin per-target Debug/Release `CODE_SIGN_STYLE`, `CODE_SIGN_IDENTITY`, and `PROVISIONING_PROFILE_SPECIFIER` values when your local machine uses explicit provisioning profiles

Unsigned or ad hoc signed builds can still launch, but macOS may ignore the File Provider extension because the App Group entitlement is not accepted at runtime. When that happens, mounts fail and Finder may show missing-file errors for the generated convenience shortcut.

## Common Commands

```bash
make generate   # regenerate MFuse.xcodeproj from project.yml
make test       # run the stable package test subset (alias of test-stable)
make test-all   # run the full package test matrix
make lint       # run SwiftLint
make build      # build the app scheme
make debug-install-app  # build a signed Debug app and install it to /Applications/MFuse.app
make clean      # remove build outputs
```

`make debug-install-app` runs `scripts/release/build-and-install-app.sh`, archives the `MFuse` scheme in `Debug` using the signing settings already configured in the current `MFuse.xcodeproj`, validates that the archived app and extension embed profiles authorizing the shared App Group, and then installs the archived app to `/Applications/MFuse.app`.

This local install flow now follows the signing configuration that Xcode is already using for the targets. If the current project settings point to explicit provisioning profiles, those profiles still need to authorize `group.com.lollipopkit.mfuse.shared` in `com.apple.security.application-groups`.

The generic `Mac Team Provisioning Profile: *` is not sufficient. It omits the App Group entitlement, which causes macOS Sequoia to show the “would like to access data from other apps” launch prompt, prevents the File Provider extension from appearing in System Settings, and leaves Finder mounts empty or redirected into the shared container. The install script still refuses to copy that broken build into `/Applications`.

If you want to install somewhere else during local verification, override the target path:

```bash
INSTALL_PATH=/tmp/MFuse.app make debug-install-app
```

## Local Release DMG

The repository includes local release scripts for building a signed, notarized `DMG` on your Mac:

- `scripts/release/install-apple-signing.sh`
- `scripts/release/cleanup-apple-signing.sh`
- `scripts/release/build-and-notarize-dmg.sh`
- `scripts/release/release-dmg.sh`

Required local inputs:

- `APPLE_DEVELOPER_ID_APP_P12_PATH`
- `APPLE_DEVELOPER_ID_APP_P12_PASSWORD`
- `APPLE_DEVELOPER_ID_APP_PROFILE_PATH`
- `APPLE_DEVELOPER_ID_EXTENSION_PROFILE_PATH`
- `APPLE_TEAM_ID`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`
- `APPLE_NOTARY_API_KEY_PATH`

The scripts load `.env` from the repository root by default. Environment variables exported in the shell still take precedence. A starter template is provided at `.env.release.example`.

Typical flow:

- install the Developer ID Application certificate and two provisioning profiles into a temporary local keychain
- regenerate `MFuse.xcodeproj` from `project.yml`
- archive and export a `Release` build with `developer-id` signing
- build and sign a `DMG`
- notarize the `DMG` with `notarytool` and staple the ticket
- restore the previous default keychain and remove temporary signing assets automatically

Example:

```bash
cp .env.release.example .env
# edit .env

make generate
make release-dmg
```

`make release-dmg` now performs install, build, notarization, and cleanup in one run. If you need manual control, use `make release-install-signing` and `make release-clean-signing`.

`PKG` is intentionally not included here. It requires a separate `Developer ID Installer` certificate.

## Testing

Current test coverage is centered on Swift packages, especially:

- `MFuseCore` core models and connection management
- `MFuseFTP` parser behavior
- `MFuseWebDAV` XML parsing

Some backend tests are placeholders or integration-oriented, so protocol coverage is not uniform yet.

## License

MFuse is licensed under the GNU Affero General Public License v3.0. See [LICENSE](LICENSE).

Third-party dependencies remain under their own licenses. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the current dependency notice summary.
