import Foundation
import MFuseCore

public actor DropboxFileSystem: RemoteFileSystem {
    private enum Constants {
        static let apiBase = "https://api.dropboxapi.com/2"
        static let contentBase = "https://content.dropboxapi.com/2"
        static let uploadChunkSize = 8 * 1024 * 1024
    }

    private let config: ConnectionConfig
    private var credential: Credential
    private let onCredentialUpdated: (@Sendable (Credential) async throws -> Void)?
    private let session: URLSession
    private let oauthProvider: DropboxOAuthProvider?
    private let oauthProviderLoadError: Error?
    private var accessToken: String?

    public var isConnected: Bool { accessToken != nil }

    public init(
        config: ConnectionConfig,
        credential: Credential,
        oauthProvider: DropboxOAuthProvider? = nil,
        session: URLSession = .shared,
        onCredentialUpdated: (@Sendable (Credential) async throws -> Void)? = nil
    ) {
        self.config = config
        self.credential = credential
        self.onCredentialUpdated = onCredentialUpdated
        self.session = session
        if let oauthProvider {
            self.oauthProvider = oauthProvider
            self.oauthProviderLoadError = nil
        } else {
            do {
                self.oauthProvider = try DropboxOAuthProvider.builtIn(bundle: .main, session: session)
                self.oauthProviderLoadError = nil
            } catch {
                self.oauthProvider = nil
                self.oauthProviderLoadError = error
            }
        }
    }

    public func connect() async throws {
        guard let token = credential.token, !token.isEmpty else {
            accessToken = nil
            throw RemoteFileSystemError.authenticationFailed
        }

        do {
            try await validateCurrentAccount(token: token)
            accessToken = token
        } catch RemoteFileSystemError.authenticationFailed {
            let refreshedToken = try await refreshAccessToken()
            do {
                try await validateCurrentAccount(token: refreshedToken)
                accessToken = refreshedToken
            } catch {
                accessToken = nil
                throw error
            }
        } catch {
            accessToken = nil
            throw error
        }
    }

    public func disconnect() async throws {
        accessToken = nil
        credential = credentialWithoutAccessToken()
        try await onCredentialUpdated?(credential)
    }

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        let result = try await listFolder(path: path)
        return result.map { metadata in
            RemoteItem(
                path: path.appending(metadata.name),
                type: metadata.remoteItemType,
                size: metadata.size ?? 0,
                modificationDate: metadata.modificationDate ?? Date(),
                creationDate: metadata.clientModificationDate,
                isHidden: metadata.name.hasPrefix(".")
            )
        }
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        guard !path.isRoot else {
            return RemoteItem(path: path, type: .directory, size: 0, modificationDate: Date())
        }

        let metadata = try await metadata(for: path)
        return RemoteItem(
            path: path,
            type: metadata.remoteItemType,
            size: metadata.size ?? 0,
            modificationDate: metadata.modificationDate ?? Date(),
            creationDate: metadata.clientModificationDate,
            isHidden: metadata.name.hasPrefix(".")
        )
    }

    public func readFile(at path: RemotePath) async throws -> Data {
        let metadata = try await metadata(for: path)
        guard metadata.tag == "file" else {
            throw RemoteFileSystemError.notFile(path)
        }
        if metadata.isDownloadable == false {
            throw RemoteFileSystemError.unsupported(
                "Dropbox item \(path.absoluteString) is not directly downloadable"
            )
        }

        var request = try authorizedRequest(
            urlString: "\(Constants.contentBase)/files/download",
            method: "POST"
        )
        request.setValue(
            try encodedDropboxAPIArg(["path": pathString(for: path)]),
            forHTTPHeaderField: "Dropbox-API-Arg"
        )
        let (data, response) = try await data(for: request)
        try check(response: response, data: data, path: path)
        return data
    }

    public func writeFile(at path: RemotePath, data: Data) async throws {
        _ = try await metadata(for: path)
        try await upload(data: data, to: path, mode: "overwrite", allowConflict: false)
    }

    public func writeFile(at path: RemotePath, from localFileURL: URL) async throws {
        _ = try await metadata(for: path)
        try await uploadFile(from: localFileURL, to: path, mode: "overwrite", strictConflict: false)
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        try await ensureAbsent(path)
        try await upload(data: data, to: path, mode: "add", allowConflict: false)
    }

    public func createFile(at path: RemotePath, from localFileURL: URL) async throws {
        try await ensureAbsent(path)
        try await uploadFile(from: localFileURL, to: path, mode: "add", strictConflict: true)
    }

    public func createDirectory(at path: RemotePath) async throws {
        try await ensureAbsent(path)
        let request = try jsonRequest(
            endpoint: "/files/create_folder_v2",
            body: [
                "path": pathString(for: path),
                "autorename": false,
            ]
        )
        let (data, response) = try await data(for: request)
        try check(response: response, data: data, path: path, conflictPath: path)
    }

    public func delete(at path: RemotePath) async throws {
        let request = try jsonRequest(
            endpoint: "/files/delete_v2",
            body: ["path": pathString(for: path)]
        )
        let (data, response) = try await data(for: request)
        try check(response: response, data: data, path: path)
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        try await ensureAbsent(destination)
        let request = try jsonRequest(
            endpoint: "/files/move_v2",
            body: [
                "from_path": pathString(for: source),
                "to_path": pathString(for: destination),
                "autorename": false,
                "allow_shared_folder": true,
            ]
        )
        let (data, response) = try await data(for: request)
        try check(response: response, data: data, path: source, conflictPath: destination)
    }

    public func copy(from source: RemotePath, to destination: RemotePath) async throws {
        try await ensureAbsent(destination)
        let request = try jsonRequest(
            endpoint: "/files/copy_v2",
            body: [
                "from_path": pathString(for: source),
                "to_path": pathString(for: destination),
                "autorename": false,
            ]
        )
        let (data, response) = try await data(for: request)
        try check(response: response, data: data, path: source, conflictPath: destination)
    }

    private func listFolder(path: RemotePath) async throws -> [DropboxMetadata] {
        let initialRequest = try jsonRequest(
            endpoint: "/files/list_folder",
            body: [
                "path": pathString(for: path),
                "include_deleted": false,
            ]
        )
        let (initialData, initialResponse) = try await data(for: initialRequest)
        try check(response: initialResponse, data: initialData, path: path)

        var decoded = try Self.jsonDecoder.decode(DropboxListFolderResponse.self, from: initialData)
        var entries = decoded.entries
        while decoded.hasMore {
            let continueRequest = try jsonRequest(
                endpoint: "/files/list_folder/continue",
                body: ["cursor": decoded.cursor]
            )
            let (nextData, nextResponse) = try await data(for: continueRequest)
            try check(response: nextResponse, data: nextData, path: path)
            decoded = try Self.jsonDecoder.decode(DropboxListFolderResponse.self, from: nextData)
            entries.append(contentsOf: decoded.entries)
        }
        return entries.filter { $0.tag == "file" || $0.tag == "folder" }
    }

    private func metadata(for path: RemotePath) async throws -> DropboxMetadata {
        let request = try jsonRequest(
            endpoint: "/files/get_metadata",
            body: [
                "path": pathString(for: path),
                "include_deleted": false,
            ]
        )
        let (data, response) = try await data(for: request)
        try check(response: response, data: data, path: path)
        return try Self.jsonDecoder.decode(DropboxMetadata.self, from: data)
    }

    private func ensureAbsent(_ path: RemotePath) async throws {
        do {
            _ = try await metadata(for: path)
            throw RemoteFileSystemError.alreadyExists(path)
        } catch RemoteFileSystemError.notFound {
            return
        }
    }

    private func upload(
        data: Data,
        to path: RemotePath,
        mode: String,
        allowConflict: Bool
    ) async throws {
        var request = try authorizedRequest(
            urlString: "\(Constants.contentBase)/files/upload",
            method: "POST"
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(
            try encodedDropboxAPIArg([
                "path": pathString(for: path),
                "mode": mode,
                "autorename": false,
                "strict_conflict": !allowConflict,
            ]),
            forHTTPHeaderField: "Dropbox-API-Arg"
        )
        request.httpBody = data
        let (responseData, response) = try await self.data(for: request)
        try check(response: response, data: responseData, path: path, conflictPath: path)
    }

    private func uploadFile(
        from localFileURL: URL,
        to path: RemotePath,
        mode: String,
        strictConflict: Bool
    ) async throws {
        let fileSize = try localFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if fileSize <= Constants.uploadChunkSize {
            let data = try Data(contentsOf: localFileURL)
            try await upload(data: data, to: path, mode: mode, allowConflict: !strictConflict)
            return
        }

        let fileHandle = try FileHandle(forReadingFrom: localFileURL)
        defer { try? fileHandle.close() }

        let firstChunk = try fileHandle.read(upToCount: Constants.uploadChunkSize) ?? Data()
        guard !firstChunk.isEmpty else {
            throw RemoteFileSystemError.operationFailed(
                "Dropbox upload failed: unexpected EOF while reading \(localFileURL.path) at offset 0 of \(fileSize); the file may have been modified during upload"
            )
        }
        var startRequest = try authorizedRequest(
            urlString: "\(Constants.contentBase)/files/upload_session/start",
            method: "POST"
        )
        startRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        startRequest.setValue(
            try encodedDropboxAPIArg(["close": false]),
            forHTTPHeaderField: "Dropbox-API-Arg"
        )
        let (startData, startResponse) = try await upload(for: startRequest, data: firstChunk)
        try check(response: startResponse, data: startData, path: path)
        let start = try JSONDecoder().decode(DropboxUploadSessionStart.self, from: startData)
        var offset = UInt64(firstChunk.count)

        while true {
            let chunk = try fileHandle.read(upToCount: Constants.uploadChunkSize) ?? Data()
            guard !chunk.isEmpty else {
                throw RemoteFileSystemError.operationFailed(
                    "Dropbox upload failed: unexpected EOF while reading \(localFileURL.path) at offset \(offset) of \(fileSize); the file may have been modified during upload"
                )
            }

            let nextChunk = try fileHandle.read(upToCount: Constants.uploadChunkSize) ?? Data()
            if nextChunk.isEmpty {
                var finishRequest = try authorizedRequest(
                    urlString: "\(Constants.contentBase)/files/upload_session/finish",
                    method: "POST"
                )
                finishRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                finishRequest.setValue(
                    try encodedDropboxAPIArg([
                        "cursor": [
                            "session_id": start.sessionID,
                            "offset": offset,
                        ],
                        "commit": [
                            "path": pathString(for: path),
                            "mode": mode,
                            "autorename": false,
                            "strict_conflict": strictConflict,
                        ],
                    ]),
                    forHTTPHeaderField: "Dropbox-API-Arg"
                )
                let (finishData, finishResponse) = try await upload(for: finishRequest, data: chunk)
                try check(response: finishResponse, data: finishData, path: path, conflictPath: path)
                break
            }

            var appendRequest = try authorizedRequest(
                urlString: "\(Constants.contentBase)/files/upload_session/append_v2",
                method: "POST"
            )
            appendRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            appendRequest.setValue(
                try encodedDropboxAPIArg([
                    "cursor": [
                        "session_id": start.sessionID,
                        "offset": offset,
                    ],
                    "close": false,
                ]),
                forHTTPHeaderField: "Dropbox-API-Arg"
            )
            let (_, appendResponse) = try await upload(for: appendRequest, data: chunk)
            try check(response: appendResponse, data: Data(), path: path)
            offset += UInt64(chunk.count)
            try fileHandle.seek(toOffset: offset)
        }
    }

    private func validateCurrentAccount(token: String) async throws {
        var request = URLRequest(url: URL(string: "\(Constants.apiBase)/users/get_current_account")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let (data, response) = try await session.data(for: request)
        try check(response: response, data: data, path: nil)
    }

    private func refreshAccessToken() async throws -> String {
        guard let refreshToken = credential.password, !refreshToken.isEmpty else {
            throw RemoteFileSystemError.authenticationFailed
        }

        let oauthProvider = try requireOAuthProvider()
        let refreshed = try await oauthProvider.refresh(refreshToken: refreshToken)
        let updatedCredential = oauthProvider.credential(
            from: refreshed,
            fallbackRefreshToken: credential.password
        )
        try await onCredentialUpdated?(updatedCredential)
        credential = updatedCredential
        guard let token = updatedCredential.token, !token.isEmpty else {
            throw RemoteFileSystemError.authenticationFailed
        }
        return token
    }

    private func jsonRequest(
        endpoint: String,
        body: [String: Any]
    ) throws -> URLRequest {
        var request = try authorizedRequest(
            urlString: "\(Constants.apiBase)\(endpoint)",
            method: "POST"
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func authorizedRequest(
        urlString: String,
        method: String
    ) throws -> URLRequest {
        guard let token = accessToken, !token.isEmpty else {
            throw RemoteFileSystemError.notConnected
        }
        guard let url = URL(string: urlString) else {
            throw RemoteFileSystemError.operationFailed("Invalid Dropbox URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func credentialWithoutAccessToken() -> Credential {
        Credential(
            password: credential.password,
            privateKey: credential.privateKey,
            passphrase: credential.passphrase,
            accessKeyID: credential.accessKeyID,
            secretAccessKey: credential.secretAccessKey,
            token: nil
        )
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result = try await session.data(for: request)
        if let http = result.1 as? HTTPURLResponse, http.statusCode == 401 {
            do {
                let refreshedToken = try await refreshAccessToken()
                accessToken = refreshedToken
                var retriedRequest = request
                retriedRequest.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
                let retriedResult = try await session.data(for: retriedRequest)
                if let retriedHTTP = retriedResult.1 as? HTTPURLResponse,
                   retriedHTTP.statusCode == 401 {
                    accessToken = nil
                    throw RemoteFileSystemError.authenticationFailed
                }
                return retriedResult
            } catch {
                accessToken = nil
                throw error
            }
        }
        return result
    }

    private func upload(for request: URLRequest, data: Data) async throws -> (Data, URLResponse) {
        let result = try await session.upload(for: request, from: data)
        if let http = result.1 as? HTTPURLResponse, http.statusCode == 401 {
            do {
                let refreshedToken = try await refreshAccessToken()
                accessToken = refreshedToken
                var retriedRequest = request
                retriedRequest.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
                let retriedResult = try await session.upload(for: retriedRequest, from: data)
                if let retriedHTTP = retriedResult.1 as? HTTPURLResponse,
                   retriedHTTP.statusCode == 401 {
                    accessToken = nil
                    throw RemoteFileSystemError.authenticationFailed
                }
                return retriedResult
            } catch {
                accessToken = nil
                throw error
            }
        }
        return result
    }

    private func check(
        response: URLResponse,
        data: Data,
        path: RemotePath?,
        conflictPath: RemotePath? = nil
    ) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200...299:
            return
        case 401:
            throw RemoteFileSystemError.authenticationFailed
        case 403:
            if let path {
                throw RemoteFileSystemError.permissionDenied(path)
            }
            throw DropboxHTTPError(statusCode: http.statusCode, summary: extractSummary(data))
        case 404:
            if let path {
                throw RemoteFileSystemError.notFound(path)
            }
            throw DropboxHTTPError(statusCode: http.statusCode, summary: extractSummary(data))
        case 409:
            let summary = extractSummary(data)
            if summary.contains("not_found"), let path {
                throw RemoteFileSystemError.notFound(path)
            }
            if summary.contains("conflict") || summary.contains("already_exists") || summary.contains("already exists") {
                if let conflictPath {
                    throw RemoteFileSystemError.alreadyExists(conflictPath)
                }
            }
            throw RemoteFileSystemError.operationFailed("Dropbox API conflict: \(summary)")
        default:
            throw DropboxHTTPError(statusCode: http.statusCode, summary: extractSummary(data))
        }
    }

    private func extractSummary(_ data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(DropboxErrorEnvelope.self, from: data) {
            return decoded.errorSummary
        }
        return String(data: data, encoding: .utf8) ?? "Unknown Dropbox error"
    }

    private func encodedDropboxAPIArg(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else {
            throw RemoteFileSystemError.operationFailed("Failed to encode Dropbox-API-Arg")
        }
        return string
    }

    private func pathString(for path: RemotePath) -> String {
        path.isRoot ? "" : path.absoluteString
    }

    private func requireOAuthProvider() throws -> DropboxOAuthProvider {
        if let oauthProvider {
            return oauthProvider
        }
        if let oauthProviderLoadError {
            throw oauthProviderLoadError
        }
        throw RemoteFileSystemError.operationFailed(
            "Dropbox OAuth provider is unavailable"
        )
    }

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private struct DropboxListFolderResponse: Decodable {
    let entries: [DropboxMetadata]
    let cursor: String
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case entries
        case cursor
        case hasMore = "has_more"
    }
}

private struct DropboxMetadata: Decodable {
    let tag: String
    let name: String
    let size: UInt64?
    let clientModified: Date?
    let serverModified: Date?
    let isDownloadable: Bool?

    enum CodingKeys: String, CodingKey {
        case tag = ".tag"
        case name
        case size
        case clientModified = "client_modified"
        case serverModified = "server_modified"
        case isDownloadable = "is_downloadable"
    }

    var modificationDate: Date? { serverModified ?? clientModified }
    var clientModificationDate: Date? { clientModified }

    var remoteItemType: RemoteItemType {
        tag == "folder" ? .directory : .file
    }
}

private struct DropboxUploadSessionStart: Decodable {
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

private struct DropboxErrorEnvelope: Decodable {
    let errorSummary: String

    enum CodingKeys: String, CodingKey {
        case errorSummary = "error_summary"
    }
}

private struct DropboxHTTPError: Error {
    let statusCode: Int
    let summary: String
}
