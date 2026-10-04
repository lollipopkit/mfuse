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

- `nfs.swift`
  - Source: `https://github.com/lollipopkit/nfs.swift`
  - Used by: `Packages/MFuseNFS`
- `swift-nio`
  - Source: `https://github.com/apple/swift-nio`
  - Used by: `Packages/MFuseFTP`, `Packages/MFuseNFS` (through `nfs.swift`)
- `swift-nio-ssl`
  - Source: `https://github.com/apple/swift-nio-ssl`
  - Used by: `Packages/MFuseFTP`
- `swift-nio-transport-services`
  - Source: `https://github.com/apple/swift-nio-transport-services`
  - Used by: `Packages/MFuseFTP`
- `soto`
  - Source: `https://github.com/soto-project/soto`
  - Used by: `Packages/MFuseS3`

### Transitive dependencies

Pulled in by the packages above; the full set the app is built with is pinned in `MFuse.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

MIT:

- `BigInt` (`https://github.com/attaswift/BigInt`)

Apache-2.0:

- `async-http-client` (`https://github.com/swift-server/async-http-client`)
- `jmespath.swift` (`https://github.com/jmespath/jmespath.swift`)
- `soto-core` (`https://github.com/soto-project/soto-core`)
- `swift-algorithms` (`https://github.com/apple/swift-algorithms`)
- `swift-asn1` (`https://github.com/apple/swift-asn1`)
- `swift-async-algorithms` (`https://github.com/apple/swift-async-algorithms`)
- `swift-atomics` (`https://github.com/apple/swift-atomics`)
- `swift-certificates` (`https://github.com/apple/swift-certificates`)
- `swift-collections` (`https://github.com/apple/swift-collections`)
- `swift-configuration` (`https://github.com/apple/swift-configuration`)
- `swift-crypto` (`https://github.com/apple/swift-crypto`)
- `swift-distributed-tracing` (`https://github.com/apple/swift-distributed-tracing`)
- `swift-http-structured-headers` (`https://github.com/apple/swift-http-structured-headers`)
- `swift-http-types` (`https://github.com/apple/swift-http-types`)
- `swift-log` (`https://github.com/apple/swift-log`)
- `swift-metrics` (`https://github.com/apple/swift-metrics`)
- `swift-nio-extras` (`https://github.com/apple/swift-nio-extras`)
- `swift-nio-http2` (`https://github.com/apple/swift-nio-http2`)
- `swift-nio-ssh` (`https://github.com/Wellz26/swift-nio-ssh`, a fork of `https://github.com/apple/swift-nio-ssh`)
- `swift-numerics` (`https://github.com/apple/swift-numerics`)
- `swift-service-context` (`https://github.com/apple/swift-service-context`)
- `swift-service-lifecycle` (`https://github.com/swift-server/swift-service-lifecycle`)
- `swift-system` (`https://github.com/apple/swift-system`)

`swift-nio-ssl` and `swift-crypto` embed BoringSSL, which carries its own OpenSSL- and ISC-style licenses in those repositories.

## Notes

- Apple system frameworks such as `FileProvider.framework` are provided by the operating system and are not redistributed as part of this repository.
- This file is a repository-level notice summary, not a replacement for upstream license texts.
- When adding new dependencies, update this file and preserve any required upstream notices.
