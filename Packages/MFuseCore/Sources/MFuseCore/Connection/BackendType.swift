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
    case dropbox
    case oneDrive

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
        case .dropbox:
            return MFuseCoreL10n.string(
                "backend.dropbox",
                fallback: "Dropbox"
            )
        case .oneDrive:
            return MFuseCoreL10n.string(
                "backend.oneDrive",
                fallback: "OneDrive"
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
        case .dropbox:     return 443
        case .oneDrive:    return 443
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
        case .dropbox:     return "shippingbox"
        case .oneDrive:    return "cloud"
        }
    }

    public var requiresServerEndpoint: Bool {
        switch self {
        case .googleDrive, .dropbox, .oneDrive:
            return false
        default:
            return true
        }
    }

    /// Whether the connection is addressed by host, port and username.
    ///
    /// S3 addresses the server through its endpoint parameter and the OAuth providers
    /// through the signed-in account, so for those the three fields hold no meaningful
    /// value and must not be offered or displayed.
    public var usesHostBasedAddressing: Bool {
        switch self {
        case .sftp, .webdav, .smb, .nfs, .ftp:
            return true
        case .s3, .googleDrive, .dropbox, .oneDrive:
            return false
        }
    }

    /// Whether the connection is identified by a username.
    ///
    /// NFS authorizes by the client's UID rather than by name — it is anonymous-only —
    /// so the field holds nothing the backend can use. Offering it would only carry a
    /// username from whichever backend was selected before into `connections.json` and
    /// every File Provider bootstrap snapshot.
    public var usesUsername: Bool {
        switch self {
        case .sftp, .webdav, .smb, .ftp:
            return true
        case .nfs, .s3, .googleDrive, .dropbox, .oneDrive:
            return false
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
        case .dropbox:     return [.oauth]
        case .oneDrive:    return [.oauth]
        }
    }
}
