import Foundation

/// Supported remote filesystem backend types.
public enum BackendType: String, Codable, Sendable, CaseIterable, Identifiable {
    case sftp
    case s3
    case webdav
    case smb
    case nfs
    case ftp
    case googleDrive

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sftp:        return "SFTP"
        case .s3:          return "S3"
        case .webdav:      return "WebDAV"
        case .smb:         return "SMB"
        case .nfs:         return "NFS"
        case .ftp:         return "FTP"
        case .googleDrive:
            return MFuseCoreL10n.string(
                "backend.googleDrive",
                fallback: "Google Drive"
            )
        }
    }

    public var defaultPort: UInt16 {
        switch self {
        case .sftp:        return 22
        case .s3:          return 443
        case .webdav:      return 443
        case .smb:         return 445
        case .nfs:         return 2049
        case .ftp:         return 21
        case .googleDrive: return 443
        }
    }

    public var iconName: String {
        switch self {
        case .sftp:        return "lock.shield"
        case .s3:          return "cloud"
        case .webdav:      return "globe"
        case .smb:         return "network"
        case .nfs:         return "externaldrive.connected.to.line.below"
        case .ftp:         return "arrow.up.arrow.down"
        case .googleDrive: return "icloud.and.arrow.down"
        }
    }

    /// Auth methods applicable to this backend type.
    public var supportedAuthMethods: [AuthMethod] {
        switch self {
        case .sftp:        return [.password, .publicKey, .agent]
        case .s3:          return [.accessKey]
        case .webdav:      return [.password, .anonymous]
        case .smb:         return [.password]
        case .nfs:         return [.anonymous]
        case .ftp:         return [.password, .anonymous]
        case .googleDrive: return [.oauth]
        }
    }
}
