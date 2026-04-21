import Foundation
import MFuseCore

/// Google Drive implementation of `RemoteFileSystem` using the REST API v3.
///
/// Uses OAuth 2.0 tokens stored in `Credential.token` (access token) and
/// `Credential.password` (refresh token). `config.parameters["clientID"]` and
/// `config.parameters["redirectURI"]` configure the OAuth client.
public actor GoogleDriveFileSystem: RemoteFileSystem {
    private struct CachedPathEntry: Sendable {
        let fileID: String
        let isFolder: Bool
    }

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterFallback = ISO8601DateFormatter()

    private let config: ConnectionConfig
    private var credential: Credential
    private let onCredentialUpdated: (@Sendable (Credential) async throws -> Void)?
    private var accessToken: String?
    private var pathToIDCache: [String: CachedPathEntry] = [
        "/": CachedPathEntry(fileID: "root", isFolder: true)
    ]
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
            self.accessToken = nil
            throw RemoteFileSystemError.authenticationFailed
        }

        do {
            // Validate token by fetching about
            let req = try authorizedRequest(url: "\(Self.apiBase)/about?fields=user", token: token)
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteFileSystemError.connectionFailed("Invalid response")
            }

            if http.statusCode == 401 {
                // Try refresh
                if let refreshToken = credential.password {
                    let clientID = config.parameters["clientID"] ?? ""
                    let redirectURI = config.parameters["redirectURI"] ?? ""
                    guard !clientID.isEmpty, !redirectURI.isEmpty else {
                        throw RemoteFileSystemError.connectionFailed(
                            "Google Drive OAuth refresh requires non-empty clientID and redirectURI"
                        )
                    }
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
            } else if http.statusCode == 200 {
                self.accessToken = token
            } else {
                throw RemoteFileSystemError.connectionFailed("Google Drive API returned \(http.statusCode)")
            }
        } catch {
            self.accessToken = nil
            throw error
        }
    }

    public func disconnect() async throws {
        accessToken = nil
        pathToIDCache = ["/": CachedPathEntry(fileID: "root", isFolder: true)]
    }

    // MARK: - Enumeration

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        let folderID = try await resolveFileID(for: path, expectFolder: true)
        var items: [RemoteItem] = []
        var pageToken: String?

        repeat {
            guard var components = URLComponents(string: "\(Self.apiBase)/files") else {
                throw RemoteFileSystemError.operationFailed("Invalid Google Drive files endpoint")
            }
            components.queryItems = [
                URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed=false"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,createdTime)"),
                URLQueryItem(name: "pageSize", value: "1000")
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            guard let urlStr = components.url?.absoluteString else {
                throw RemoteFileSystemError.operationFailed("Failed to construct Google Drive enumeration URL")
            }

            let req = try authorizedRequest(url: urlStr)
            let (data, response) = try await executeAuthorizedRequest(req, path: path)
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
        let (data, response) = try await executeAuthorizedRequest(req, path: path)
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
        let (data, response) = try await executeAuthorizedRequest(req, path: path)
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

        let (_, response) = try await executeAuthorizedRequest(req, path: path)
        try checkHTTPResponse(response, path: path)
    }

    public func writeFile(at path: RemotePath, from localFileURL: URL) async throws {
        let fileID = try await resolveFileID(for: path)
        let urlStr = "\(Self.uploadBase)/files/\(fileID)?uploadType=media"
        var req = try authorizedRequest(url: urlStr)
        req.httpMethod = "PATCH"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await executeAuthorizedUpload(req, from: localFileURL, path: path)
        try checkHTTPResponse(response, path: path)
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        guard let parentPath = path.parent else { throw RemoteFileSystemError.operationFailed("Cannot create file at root") }
        do {
            _ = try await resolveFileID(for: path, expectFolder: false)
            throw RemoteFileSystemError.alreadyExists(path)
        } catch RemoteFileSystemError.notFound {
            // Expected path for create-only semantics.
        } catch {
            throw error
        }
        let parentID = try await resolveFileID(for: parentPath, expectFolder: true)
        let name = path.name

        // Multipart upload: metadata + content
        let boundary = UUID().uuidString
        let metadata: [String: Any] = [
            "name": name,
            "parents": [parentID]
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(metadataJSON)
        body.append(Data("\r\n--\(boundary)\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = try authorizedRequest(url: "\(Self.uploadBase)/files?uploadType=multipart")
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        let (responseData, response) = try await executeAuthorizedRequest(req, path: path)
        try checkHTTPResponse(response, path: path)
        if let fileID = try parseFileID(from: responseData) {
            cacheResolvedID(fileID, isFolder: false, for: path)
        } else {
            invalidateCachedPath(path)
        }
    }

    public func createFile(at path: RemotePath, from localFileURL: URL) async throws {
        guard let parentPath = path.parent else { throw RemoteFileSystemError.operationFailed("Cannot create file at root") }
        do {
            _ = try await resolveFileID(for: path, expectFolder: false)
            throw RemoteFileSystemError.alreadyExists(path)
        } catch RemoteFileSystemError.notFound {
            // Expected path for create-only semantics.
        } catch {
            throw error
        }
        let parentID = try await resolveFileID(for: parentPath, expectFolder: true)
        let name = path.name

        let boundary = UUID().uuidString
        let metadata: [String: Any] = [
            "name": name,
            "parents": [parentID]
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)
        let multipartURL = try makeMultipartUploadFile(
            metadataJSON: metadataJSON,
            sourceFileURL: localFileURL,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: multipartURL) }

        var req = try authorizedRequest(url: "\(Self.uploadBase)/files?uploadType=multipart")
        req.httpMethod = "POST"
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (responseData, response) = try await executeAuthorizedUpload(req, from: multipartURL, path: path)
        try checkHTTPResponse(response, path: path)
        if let fileID = try parseFileID(from: responseData) {
            cacheResolvedID(fileID, isFolder: false, for: path)
        } else {
            invalidateCachedPath(path)
        }
    }

    // MARK: - Mutations

    public func createDirectory(at path: RemotePath) async throws {
        guard let parentPath = path.parent else { throw RemoteFileSystemError.operationFailed("Cannot create directory at root") }
        do {
            _ = try await resolveFileID(for: path)
            throw RemoteFileSystemError.alreadyExists(path)
        } catch RemoteFileSystemError.notFound {
            // Expected path for create-only semantics.
        } catch {
            throw error
        }
        let parentID = try await resolveFileID(for: parentPath, expectFolder: true)
        let name = path.name

        let metadata: [String: Any] = [
            "name": name,
            "mimeType": Self.folderMime,
            "parents": [parentID]
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata)

        var req = try authorizedRequest(url: "\(Self.apiBase)/files")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = metadataJSON

        let (responseData, response) = try await executeAuthorizedRequest(req, path: path)
        try checkHTTPResponse(response, path: path)
        if let fileID = try parseFileID(from: responseData) {
            cacheResolvedID(fileID, isFolder: true, for: path)
        } else {
            invalidateCachedPath(path)
        }
    }

    public func delete(at path: RemotePath) async throws {
        let fileID = try await resolveFileID(for: path)
        var req = try authorizedRequest(url: "\(Self.apiBase)/files/\(fileID)")
        req.httpMethod = "DELETE"

        let (_, response) = try await executeAuthorizedRequest(req, path: path)
        try checkHTTPResponse(response, path: path)
        invalidateCachedPath(path)
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        if source == destination {
            return
        }

        do {
            _ = try await resolveFileID(for: destination)
            throw RemoteFileSystemError.alreadyExists(destination)
        } catch RemoteFileSystemError.notFound {
            // Expected path for create-only semantics.
        } catch {
            throw error
        }

        let fileID = try await resolveFileID(for: source)
        guard let srcParent = source.parent, let dstParent = destination.parent else {
            throw RemoteFileSystemError.operationFailed("Cannot move root")
        }
        let oldParentID = try await resolveFileID(for: srcParent, expectFolder: true)
        let newParentID = try await resolveFileID(for: dstParent, expectFolder: true)
        let newName = destination.name

        guard var components = URLComponents(string: "\(Self.apiBase)/files/\(fileID)") else {
            throw RemoteFileSystemError.operationFailed("Invalid Google Drive move endpoint")
        }
        components.queryItems = [
            URLQueryItem(name: "addParents", value: newParentID),
            URLQueryItem(name: "removeParents", value: oldParentID)
        ]
        guard let urlStr = components.url?.absoluteString else {
            throw RemoteFileSystemError.operationFailed("Failed to construct Google Drive move URL")
        }

        var req = try authorizedRequest(url: urlStr)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["name": newName]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await executeAuthorizedRequest(req, path: destination)
        try checkHTTPResponse(response, path: destination)
        let sourceIsFolder = pathToIDCache[source.absoluteString]?.isFolder ?? false
        invalidateCachedPath(source)
        invalidateCachedPath(destination)
        cacheResolvedID(fileID, isFolder: sourceIsFolder, for: destination)
    }

    public func copy(from source: RemotePath, to destination: RemotePath) async throws {
        if source == destination {
            return
        }

        do {
            _ = try await resolveFileID(for: destination)
            throw RemoteFileSystemError.alreadyExists(destination)
        } catch RemoteFileSystemError.notFound {
            // Expected path for create-only semantics.
        } catch {
            throw error
        }

        let fileID = try await resolveFileID(for: source)
        guard let dstParent = destination.parent else { throw RemoteFileSystemError.operationFailed("Cannot copy to root") }
        let destParentID = try await resolveFileID(for: dstParent, expectFolder: true)
        let newName = destination.name
        let sourceIsFolder = pathToIDCache[source.absoluteString]?.isFolder ?? false

        var req = try authorizedRequest(url: "\(Self.apiBase)/files/\(fileID)/copy")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "name": newName,
            "parents": [destParentID]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (responseData, response) = try await executeAuthorizedRequest(req, path: destination)
        try checkHTTPResponse(response, path: destination)
        if let fileID = try parseFileID(from: responseData) {
            cacheResolvedID(fileID, isFolder: sourceIsFolder, for: destination)
        } else {
            invalidateCachedPath(destination)
        }
    }

    // MARK: - Path → File ID Resolution

    /// Walk the path components to resolve a Google Drive file ID.
    /// Google Drive is ID-based, not path-based, so we must walk from root.
    private func resolveFileID(for path: RemotePath, expectFolder: Bool = false) async throws -> String {
        if path.isRoot { return "root" }
        if let cachedEntry = pathToIDCache[path.absoluteString] {
            if expectFolder && !cachedEntry.isFolder {
                throw GoogleDriveError.notAFolder(path.absoluteString)
            }
            return cachedEntry.fileID
        }

        var currentID = "root"
        let components = path.components
        var currentPath = RemotePath.root

        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            currentPath = currentPath.appending(component)
            let escapedName = component
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            let query = "'\(currentID)' in parents and name='\(escapedName)' and trashed=false"
            guard var urlComponents = URLComponents(string: "\(Self.apiBase)/files") else {
                throw RemoteFileSystemError.operationFailed("Invalid Google Drive files endpoint")
            }
            urlComponents.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "files(id,mimeType)"),
                URLQueryItem(name: "pageSize", value: "2")
            ]
            guard let urlStr = urlComponents.url?.absoluteString else {
                throw RemoteFileSystemError.operationFailed("Failed to construct Google Drive path resolution URL")
            }

            let req = try authorizedRequest(url: urlStr)
            let (data, response) = try await executeAuthorizedRequest(req, path: path)
            try checkHTTPResponse(response, path: path)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let files = json["files"] as? [[String: Any]] ?? []
            if files.isEmpty {
                throw RemoteFileSystemError.notFound(path)
            }
            guard files.count == 1 else {
                throw RemoteFileSystemError.operationFailed(
                    "Ambiguous Google Drive path resolution for \(currentPath.absoluteString)"
                )
            }
            guard let first = files.first, let fileID = first["id"] as? String else {
                throw RemoteFileSystemError.operationFailed(
                    "Google Drive path resolution returned an invalid file record for \(currentPath.absoluteString)"
                )
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
            let mime = first["mimeType"] as? String ?? ""
            cacheResolvedID(currentID, isFolder: mime == Self.folderMime, for: currentPath)
        }

        if let cachedEntry = pathToIDCache[path.absoluteString] {
            cacheResolvedID(currentID, isFolder: cachedEntry.isFolder, for: path)
        }
        return currentID
    }

    // MARK: - Helpers

    private func authorizedRequest(url urlStr: String) throws -> URLRequest {
        guard let token = accessToken else {
            throw RemoteFileSystemError.notConnected
        }
        return try authorizedRequest(url: urlStr, token: token)
    }

    private func authorizedRequest(url urlStr: String, token: String) throws -> URLRequest {
        guard let url = URL(string: urlStr) else {
            throw RemoteFileSystemError.operationFailed("Invalid URL: \(urlStr)")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func executeAuthorizedRequest(
        _ request: URLRequest,
        path _: RemotePath
    ) async throws -> (Data, URLResponse) {
        let initialResult = try await session.data(for: request)
        guard let http = initialResult.1 as? HTTPURLResponse, http.statusCode == 401 else {
            return initialResult
        }

        do {
            try await refreshAccessToken()
        } catch {
            throw RemoteFileSystemError.authenticationFailed
        }

        var retriedRequest = request
        guard let token = accessToken else {
            throw RemoteFileSystemError.authenticationFailed
        }
        retriedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let retriedResult = try await session.data(for: retriedRequest)
        if let retriedHTTP = retriedResult.1 as? HTTPURLResponse, retriedHTTP.statusCode == 401 {
            throw RemoteFileSystemError.authenticationFailed
        }
        return retriedResult
    }

    private func executeAuthorizedUpload(
        _ request: URLRequest,
        from localFileURL: URL,
        path _: RemotePath
    ) async throws -> (Data, URLResponse) {
        let initialResult = try await session.upload(for: request, fromFile: localFileURL)
        guard let http = initialResult.1 as? HTTPURLResponse, http.statusCode == 401 else {
            return initialResult
        }

        do {
            try await refreshAccessToken()
        } catch {
            throw RemoteFileSystemError.authenticationFailed
        }

        var retriedRequest = request
        guard let token = accessToken else {
            throw RemoteFileSystemError.authenticationFailed
        }
        retriedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let retriedResult = try await session.upload(for: retriedRequest, fromFile: localFileURL)
        if let retriedHTTP = retriedResult.1 as? HTTPURLResponse, retriedHTTP.statusCode == 401 {
            throw RemoteFileSystemError.authenticationFailed
        }
        return retriedResult
    }

    private func refreshAccessToken() async throws {
        guard let refreshToken = credential.password else {
            throw RemoteFileSystemError.authenticationFailed
        }

        let clientID = config.parameters["clientID"] ?? ""
        let redirectURI = config.parameters["redirectURI"] ?? ""
        guard !clientID.isEmpty, !redirectURI.isEmpty else {
            throw RemoteFileSystemError.authenticationFailed
        }

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
        credential = updatedCredential
        accessToken = newToken.accessToken
    }

    private func checkHTTPResponse(_ response: URLResponse, path: RemotePath) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299: return
        case 403: throw RemoteFileSystemError.permissionDenied(path)
        case 404: throw RemoteFileSystemError.notFound(path)
        default:
            throw RemoteFileSystemError.operationFailed("HTTP \(http.statusCode)")
        }
    }

    private func parseISO8601(_ str: String?) -> Date? {
        guard let str = str else { return nil }
        return Self.isoFormatterWithFractionalSeconds.date(from: str)
            ?? Self.isoFormatterFallback.date(from: str)
    }

    private func makeMultipartUploadFile(
        metadataJSON: Data,
        sourceFileURL: URL,
        boundary: String
    ) throws -> URL {
        let multipartURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: multipartURL.path, contents: nil)

        let outputHandle = try FileHandle(forWritingTo: multipartURL)
        let inputHandle = try FileHandle(forReadingFrom: sourceFileURL)

        do {
            defer {
                try? outputHandle.close()
                try? inputHandle.close()
            }

            try outputHandle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try outputHandle.write(contentsOf: Data("Content-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
            try outputHandle.write(contentsOf: metadataJSON)
            try outputHandle.write(contentsOf: Data("\r\n--\(boundary)\r\n".utf8))
            try outputHandle.write(contentsOf: Data("Content-Type: application/octet-stream\r\n\r\n".utf8))

            while let chunk = try inputHandle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try outputHandle.write(contentsOf: chunk)
            }

            try outputHandle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: multipartURL)
            throw error
        }

        return multipartURL
    }

    private func cacheResolvedID(_ fileID: String, isFolder: Bool, for path: RemotePath) {
        pathToIDCache[path.absoluteString] = CachedPathEntry(fileID: fileID, isFolder: isFolder)
    }

    private func invalidateCachedPath(_ path: RemotePath) {
        let prefix = path.absoluteString == "/" ? "/" : path.absoluteString + "/"
        pathToIDCache = pathToIDCache.filter { key, _ in
            key != path.absoluteString && !key.hasPrefix(prefix)
        }
        pathToIDCache["/"] = CachedPathEntry(fileID: "root", isFolder: true)
    }

    private func parseFileID(from data: Data) throws -> String? {
        guard !data.isEmpty else { return nil }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["id"] as? String
    }
}
