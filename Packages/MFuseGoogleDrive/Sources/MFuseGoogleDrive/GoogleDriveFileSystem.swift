import Foundation
import MFuseCore

/// Google Drive implementation of `RemoteFileSystem` using the REST API v3.
///
/// Uses OAuth 2.0 tokens stored in `Credential.token` (access token) and
/// `Credential.password` (refresh token). `config.parameters["clientID"]` and
/// `config.parameters["redirectURI"]` configure the OAuth client.
public actor GoogleDriveFileSystem: RemoteFileSystem {

    private let config: ConnectionConfig
    private var credential: Credential
    private let onCredentialUpdated: (@Sendable (Credential) async throws -> Void)?
    private var accessToken: String?
    private var pathToIDCache: [String: String] = ["/": "root"]
    private let session = URLSession.shared

    private static let apiBase = "https://www.googleapis.com/drive/v3"
    private static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
    private static let folderMime = "application/vnd.google-apps.folder"

    public var isConnected: Bool { accessToken != nil }

    public init(
        config: ConnectionConfig,
        credential: Credential,
        onCredentialUpdated: (@Sendable (Credential) async throws -> Void)? = nil
    ) {
        self.config = config
        self.credential = credential
        self.onCredentialUpdated = onCredentialUpdated
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        guard let token = credential.token, !token.isEmpty else {
            throw RemoteFileSystemError.authenticationFailed
        }
        self.accessToken = token

        // Validate token by fetching about
        let req = try authorizedRequest(url: "\(Self.apiBase)/about?fields=user")
        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.connectionFailed("Invalid response")
        }

        if http.statusCode == 401 {
            // Try refresh
            if let refreshToken = credential.password {
                let clientID = config.parameters["clientID"] ?? ""
                let redirectURI = config.parameters["redirectURI"] ?? ""
                let provider = GoogleOAuthProvider(clientID: clientID, redirectURI: redirectURI)
                let newToken = try await provider.refresh(refreshToken: refreshToken)
                let updatedCredential = Credential(
                    password: newToken.refreshToken ?? credential.password,
                    privateKey: credential.privateKey,
                    passphrase: credential.passphrase,
                    accessKeyID: credential.accessKeyID,
                    secretAccessKey: credential.secretAccessKey,
                    token: newToken.accessToken
                )
                try await onCredentialUpdated?(updatedCredential)
                self.credential = updatedCredential
                self.accessToken = newToken.accessToken
            } else {
                throw RemoteFileSystemError.authenticationFailed
            }
        } else if http.statusCode != 200 {
            throw RemoteFileSystemError.connectionFailed("Google Drive API returned \(http.statusCode)")
        }
    }

    public func disconnect() async throws {
        accessToken = nil
        pathToIDCache = ["/": "root"]
    }

    // MARK: - Enumeration

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        let folderID = try await resolveFileID(for: path, expectFolder: true)
        var items: [RemoteItem] = []
        var pageToken: String?

        repeat {
            var urlStr = "\(Self.apiBase)/files?q='\(folderID)'+in+parents+and+trashed=false"
            urlStr += "&fields=nextPageToken,files(id,name,mimeType,size,modifiedTime,createdTime)"
            urlStr += "&pageSize=1000"
            if let pt = pageToken {
                urlStr += "&pageToken=\(pt)"
            }

            let req = try authorizedRequest(url: urlStr)
            let (data, response) = try await session.data(for: req)
            try checkHTTPResponse(response, path: path)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let files = json["files"] as? [[String: Any]] ?? []

            for file in files {
                guard let name = file["name"] as? String else { continue }
                let mimeType = file["mimeType"] as? String ?? ""
                let isFolder = mimeType == Self.folderMime
                let size = UInt64(file["size"] as? String ?? "0") ?? 0
                let modDate = parseISO8601(file["modifiedTime"] as? String)
                let createDate = parseISO8601(file["createdTime"] as? String)

                items.append(RemoteItem(
                    path: path.appending(name),
                    type: isFolder ? .directory : .file,
                    size: size,
                    modificationDate: modDate ?? Date(),
                    creationDate: createDate
                ))
            }

            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil

        return items
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        if path.isRoot {
            return RemoteItem(path: path, type: .directory, size: 0, modificationDate: Date())
        }

        let fileID = try await resolveFileID(for: path)
        let urlStr = "\(Self.apiBase)/files/\(fileID)?fields=id,name,mimeType,size,modifiedTime,createdTime"
        let req = try authorizedRequest(url: urlStr)
        let (data, response) = try await session.data(for: req)
        try checkHTTPResponse(response, path: path)
        let file = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        let mimeType = file["mimeType"] as? String ?? ""
        let isFolder = mimeType == Self.folderMime
        let size = UInt64(file["size"] as? String ?? "0") ?? 0
        let modDate = parseISO8601(file["modifiedTime"] as? String)
        let createDate = parseISO8601(file["createdTime"] as? String)

        return RemoteItem(
            path: path,
            type: isFolder ? .directory : .file,
            size: size,
            modificationDate: modDate ?? Date(),
            creationDate: createDate
        )
    }

    // MARK: - Read

    public func readFile(at path: RemotePath) async throws -> Data {
        let fileID = try await resolveFileID(for: path)
        let urlStr = "\(Self.apiBase)/files/\(fileID)?alt=media"
        let req = try authorizedRequest(url: urlStr)
        let (data, response) = try await session.data(for: req)
        try checkHTTPResponse(response, path: path)
        return data
    }

    // MARK: - Write

    public func writeFile(at path: RemotePath, data: Data) async throws {
        let fileID = try await resolveFileID(for: path)
        let urlStr = "\(Self.uploadBase)/files/\(fileID)?uploadType=media"
        var req = try authorizedRequest(url: urlStr)
        req.httpMethod = "PATCH"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        let (_, response) = try await session.data(for: req)
        try checkHTTPResponse(response, path: path)
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        guard let parentPath = path.parent else { throw RemoteFileSystemError.operationFailed("Cannot create file at root") }
        let parentID = try await resolveFileID(for: parentPath, expectFolder: true)
        let name = path.name

        // Multipart upload: metadata + content
        let boundary = UUID().uuidString
        let metadata: [String: Any] = [
            "name": name,
            "parents": [parentID],
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        body.append(metadataJSON)
        body.append("\r\n--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = try authorizedRequest(url: "\(Self.uploadBase)/files?uploadType=multipart")
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (responseData, response) = try await session.data(for: req)
        try checkHTTPResponse(response, path: path)
        if let fileID = try parseFileID(from: responseData) {
            cacheResolvedID(fileID, for: path)
        } else {
            invalidateCachedPath(path)
        }
    }

    // MARK: - Mutations

    public func createDirectory(at path: RemotePath) async throws {
        guard let parentPath = path.parent else { throw RemoteFileSystemError.operationFailed("Cannot create directory at root") }
        let parentID = try await resolveFileID(for: parentPath, expectFolder: true)
        let name = path.name

        let metadata: [String: Any] = [
            "name": name,
            "mimeType": Self.folderMime,
            "parents": [parentID],
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)

        var req = try authorizedRequest(url: "\(Self.apiBase)/files")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = metadataJSON

        let (responseData, response) = try await session.data(for: req)
        try checkHTTPResponse(response, path: path)
        if let fileID = try parseFileID(from: responseData) {
            cacheResolvedID(fileID, for: path)
        } else {
            invalidateCachedPath(path)
        }
    }

    public func delete(at path: RemotePath) async throws {
        let fileID = try await resolveFileID(for: path)
        var req = try authorizedRequest(url: "\(Self.apiBase)/files/\(fileID)")
        req.httpMethod = "DELETE"

        let (_, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 204 && http.statusCode != 200 {
            throw RemoteFileSystemError.operationFailed("Delete failed: HTTP \(http.statusCode)")
        }
        invalidateCachedPath(path)
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        let fileID = try await resolveFileID(for: source)
        guard let srcParent = source.parent, let dstParent = destination.parent else {
            throw RemoteFileSystemError.operationFailed("Cannot move root")
        }
        let oldParentID = try await resolveFileID(for: srcParent, expectFolder: true)
        let newParentID = try await resolveFileID(for: dstParent, expectFolder: true)
        let newName = destination.name

        var urlStr = "\(Self.apiBase)/files/\(fileID)"
        urlStr += "?addParents=\(newParentID)&removeParents=\(oldParentID)"

        var req = try authorizedRequest(url: urlStr)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["name": newName]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: req)
        try checkHTTPResponse(response, path: destination)
        invalidateCachedPath(source)
        invalidateCachedPath(destination)
        cacheResolvedID(fileID, for: destination)
    }

    public func copy(from source: RemotePath, to destination: RemotePath) async throws {
        let fileID = try await resolveFileID(for: source)
        guard let dstParent = destination.parent else { throw RemoteFileSystemError.operationFailed("Cannot copy to root") }
        let destParentID = try await resolveFileID(for: dstParent, expectFolder: true)
        let newName = destination.name

        var req = try authorizedRequest(url: "\(Self.apiBase)/files/\(fileID)/copy")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "name": newName,
            "parents": [destParentID],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await session.data(for: req)
        try checkHTTPResponse(response, path: destination)
        if let fileID = try parseFileID(from: responseData) {
            cacheResolvedID(fileID, for: destination)
        } else {
            invalidateCachedPath(destination)
        }
    }

    // MARK: - Path → File ID Resolution

    /// Walk the path components to resolve a Google Drive file ID.
    /// Google Drive is ID-based, not path-based, so we must walk from root.
    private func resolveFileID(for path: RemotePath, expectFolder: Bool = false) async throws -> String {
        if path.isRoot { return "root" }
        if let cachedID = pathToIDCache[path.absoluteString] {
            return cachedID
        }

        var currentID = "root"
        let components = path.components
        var currentPath = RemotePath.root

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            currentPath = currentPath.appending(component)
            let escapedName = component.replacingOccurrences(of: "'", with: "\\'")
            let query = "'\(currentID)' in parents and name='\(escapedName)' and trashed=false"
            let urlStr = "\(Self.apiBase)/files?q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)&fields=files(id,mimeType)&pageSize=2"

            let req = try authorizedRequest(url: urlStr)
            let (data, response) = try await session.data(for: req)
            try checkHTTPResponse(response, path: path)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let files = json["files"] as? [[String: Any]] ?? []

            guard let first = files.first, let fileID = first["id"] as? String else {
                throw RemoteFileSystemError.notFound(path)
            }

            if !isLast {
                // Intermediate components must be folders
                let mime = first["mimeType"] as? String ?? ""
                guard mime == Self.folderMime else {
                    throw GoogleDriveError.notAFolder(component)
                }
            }

            if isLast && expectFolder {
                let mime = first["mimeType"] as? String ?? ""
                guard mime == Self.folderMime else {
                    throw GoogleDriveError.notAFolder(component)
                }
            }

            currentID = fileID
            cacheResolvedID(currentID, for: currentPath)
        }

        cacheResolvedID(currentID, for: path)
        return currentID
    }

    // MARK: - Helpers

    private func authorizedRequest(url urlStr: String) throws -> URLRequest {
        guard let token = accessToken else {
            throw RemoteFileSystemError.notConnected
        }
        guard let url = URL(string: urlStr) else {
            throw RemoteFileSystemError.operationFailed("Invalid URL: \(urlStr)")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func checkHTTPResponse(_ response: URLResponse, path: RemotePath) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: return
        case 401: throw RemoteFileSystemError.authenticationFailed
        case 404: throw RemoteFileSystemError.notFound(path)
        default:
            throw RemoteFileSystemError.operationFailed("HTTP \(http.statusCode)")
        }
    }

    private func parseISO8601(_ str: String?) -> Date? {
        guard let str = str else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: str) ?? ISO8601DateFormatter().date(from: str)
    }

    private func cacheResolvedID(_ fileID: String, for path: RemotePath) {
        pathToIDCache[path.absoluteString] = fileID
    }

    private func invalidateCachedPath(_ path: RemotePath) {
        let prefix = path.absoluteString == "/" ? "/" : path.absoluteString + "/"
        pathToIDCache = pathToIDCache.filter { key, _ in
            key != path.absoluteString && !key.hasPrefix(prefix)
        }
        pathToIDCache["/"] = "root"
    }

    private func parseFileID(from data: Data) throws -> String? {
        guard !data.isEmpty else { return nil }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["id"] as? String
    }
}
