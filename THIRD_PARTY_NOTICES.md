# Third-Party Notices

This repository is licensed under GNU Affero General Public License v3.0.

MFuse depends on third-party components that remain under their own licenses.
Those licenses continue to apply to the respective third-party code.

## Bundled Through Swift Package Manager

### MIT

- `Citadel`
  - Source: `https://github.com/orlandos-nl/Citadel`
  - Used by: `Packages/MFuseSFTP`
- `SMBClient`
  - Source: `https://github.com/kishikawakatsumi/SMBClient`
  - Used by: `Packages/MFuseSMB`

### ISC

- `BLAKE3`
  - Source: `https://github.com/JoshBashed/blake3-swift`
  - Used by: `Packages/MFuseCore`

### Apache-2.0

- `swift-nio`
  - Source: `https://github.com/apple/swift-nio`
  - Used by: `Packages/MFuseFTP`
- `swift-nio-ssl`
  - Source: `https://github.com/apple/swift-nio-ssl`
  - Used by: `Packages/MFuseFTP`
- `swift-nio-transport-services`
  - Source: `https://github.com/apple/swift-nio-transport-services`
  - Used by: `Packages/MFuseFTP`
- `soto`
  - Source: `https://github.com/soto-project/soto`
  - Used by: `Packages/MFuseS3`

## Notes

- Apple system frameworks such as `FileProvider.framework` are provided by the operating system and are not redistributed as part of this repository.
- This file is a repository-level notice summary, not a replacement for upstream license texts.
- When adding new dependencies, update this file and preserve any required upstream notices.
