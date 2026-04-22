import Foundation

/// Errors specific to Google Drive operations.
public enum GoogleDriveError: Error, LocalizedError {
    case oauthFailed(String)
    case apiError(Int, String)
    case fileNotFound(String)
    case notAFolder(String)
    case ambiguousPath(String)

    public var errorDescription: String? {
        switch self {
        case .oauthFailed(let msg): return "OAuth failed: \(msg)"
        case .apiError(let code, let msg): return "Google Drive API error \(code): \(msg)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .notAFolder(let path): return "\(path) is not a folder"
        case .ambiguousPath(let path): return "Ambiguous path (multiple items): \(path)"
        }
    }
}
