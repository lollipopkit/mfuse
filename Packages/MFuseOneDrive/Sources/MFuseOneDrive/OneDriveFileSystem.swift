import Foundation
import MFuseCore

public actor OneDriveFileSystem: RemoteFileSystem {
    private enum Constants {
        static let graphBase = "https://graph.microsoft.com/v1.0"
        static let uploadChunkSize = 8 * 1024 * 1024
        static let maxCopyPollCount = 60
        static let copyPollDelayNanoseconds: UInt64 = 1_000_000_000
    }

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterFallback = ISO8601DateFormatter()

    private static let encodedPathAllowedCharacters: CharacterSet = {
        var characters = CharacterSet.urlPathAllowed
        characters.remove(charactersIn: ":#%?")
        return characters
    }()

    private let config: ConnectionConfig
    private var credential: Credential
    private let onCredentialUpdated: (@Sendable (Credential) async throws -> Void)?
    private let session: URLSession
    private let oauthProvider: OneDriveOAuthProvider?
    private let oauthProviderLoadError: Error?
    private var accessToken: String?
    private var driveID: String?

    public var isConnected: Bool { accessToken != nil }

    public init(
        config: ConnectionConfig,
        credential: Credential,
        oauthProvider: OneDriveOAuthProvider? = nil,
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
                self.oauthProvider = try OneDriveOAuthProvider.builtIn(bundle: .main, session: session)
                self.oauthProviderLoadError = nil
            } catch {
                let message = "OneDriveOAuthProvider.builtIn() failed: \(error.localizedDescription). " +
                    "No valid clientID/redirectURI are available."
                NSLog("MFuse OneDrive OAuth provider unavailable: %@", message)
                self.oauthProvider = nil
                self.oauthProviderLoadError = RemoteFileSystemError.operationFailed(message)
            }
        }
    }

    public func connect() async throws {
        do {
            let token = try await initialAccessToken()
            let drive = try await drive(usingToken: token)
            accessToken = token
            driveID = drive.id
        } catch let error as OneDriveHTTPError where error.statusCode == 401 {
            do {
                try await refreshAccessToken()
                let drive = try await drive(usingToken: try currentToken())
                driveID = drive.id
            } catch {
                resetConnectionState()
                throw error
            }
        } catch {
            resetConnectionState()
            throw error
        }
    }

    public func disconnect() async throws {
        resetConnectionState()
        credential = credentialWithoutAccessToken()
        try await onCredentialUpdated?(credential)
    }

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        let url = try childrenURL(for: path)
        var items: [RemoteItem] = []
        var nextURL: URL? = url

        while let currentURL = nextURL {
            var request = try authorizedRequest(url: currentURL, method: "GET")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await data(for: request)
            try check(response: response, data: data, path: path)
            let decoded = try JSONDecoder().decode(OneDriveChildrenResponse.self, from: data)
            items.append(contentsOf: decoded.value.map { item in
                RemoteItem(
                    id: item.id,
                    path: path.appending(item.name),
                    type: item.remoteItemType,
                    size: item.size ?? 0,
                    modificationDate: item.lastModifiedDate ?? Date(),
                    creationDate: item.createdDate,
                    isHidden: item.name.hasPrefix(".")
                )
            })
            nextURL = decoded.nextLink.flatMap(URL.init(string:))
        }

        return items
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        let item = try await driveItem(at: path)
        return RemoteItem(
            id: item.id,
            path: path,
            type: item.remoteItemType,
            size: item.size ?? 0,
            modificationDate: item.lastModifiedDate ?? Date(),
            creationDate: item.createdDate,
            isHidden: item.name.hasPrefix(".")
        )
    }

    public func readFile(at path: RemotePath) async throws -> Data {
        let metadata = try await driveItem(at: path)
        guard metadata.isFile else {
            throw RemoteFileSystemError.notFile(path)
        }
        let request = try authorizedRequest(url: try contentURL(for: path), method: "GET")
        let (data, response) = try await data(for: request)
        try check(response: response, data: data, path: path)
        return data
    }

    public func readFile(at path: RemotePath, offset: UInt64, length: UInt32) async throws -> Data {
        _ = (path, offset, length)
        throw RemoteFileSystemError.unsupported("OneDrive does not support partial file reads")
    }

    public func writeFile(at path: RemotePath, data: Data) async throws {
        _ = try await driveItem(at: path)
        try await upload(data: data, to: path)
    }

    public func writeFile(at path: RemotePath, from localFileURL: URL) async throws {
        _ = try await driveItem(at: path)
        try await uploadFile(from: localFileURL, to: path)
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        try await upload(data: data, to: path, conflictBehavior: "fail")
    }

    public func createFile(at path: RemotePath, from localFileURL: URL) async throws {
        try await uploadFile(from: localFileURL, to: path, conflictBehavior: "fail")
    }

    public func createDirectory(at path: RemotePath) async throws {
        try await ensureAbsent(path)
        guard let parent = path.parent else {
            throw RemoteFileSystemError.operationFailed("Cannot create directory at root")
        }
        let parentItem = try await driveItem(at: parent)
        guard parentItem.isDirectory else {
            throw RemoteFileSystemError.notDirectory(parent)
        }

        let requestURL = try childrenURL(for: parent)
        var request = try authorizedRequest(url: requestURL, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": path.name,
            "folder": [:],
            "@microsoft.graph.conflictBehavior": "fail",
        ])
        let (data, response) = try await data(for: request)
        try check(response: response, data: data, path: path, conflictPath: path)
    }

    public func delete(at path: RemotePath) async throws {
        let item = try await driveItem(at: path)
        let request = try authorizedRequest(url: itemByIDURL(item.id), method: "DELETE")
        let (data, response) = try await data(for: request)
        try check(response: response, data: data, path: path)
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        try await ensureAbsent(destination)
        let sourceItem = try await driveItem(at: source)
        guard let destinationParentPath = destination.parent else {
            throw RemoteFileSystemError.operationFailed("Cannot move item to root alias")
        }
        let destinationParent = try await driveItem(at: destinationParentPath)
        guard destinationParent.isDirectory else {
            throw RemoteFileSystemError.notDirectory(destinationParentPath)
        }

        var request = try authorizedRequest(url: itemByIDURL(sourceItem.id), method: "PATCH")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": destination.name,
            "parentReference": [
                "id": destinationParent.id,
                "driveId": try currentDriveID(),
            ],
        ])
        let (data, response) = try await data(for: request)
        try check(response: response, data: data, path: source, conflictPath: destination)
    }

    public func copy(from source: RemotePath, to destination: RemotePath) async throws {
        try await ensureAbsent(destination)
        let sourceItem = try await driveItem(at: source)
        guard let destinationParentPath = destination.parent else {
            throw RemoteFileSystemError.operationFailed("Cannot copy item to root alias")
        }
        let destinationParent = try await driveItem(at: destinationParentPath)
        guard destinationParent.isDirectory else {
            throw RemoteFileSystemError.notDirectory(destinationParentPath)
        }

        guard var components = URLComponents(url: itemByIDURL(sourceItem.id).appendingPathComponent("copy"), resolvingAgainstBaseURL: false) else {
            throw RemoteFileSystemError.operationFailed("Failed to build OneDrive copy URL")
        }
        components.queryItems = [URLQueryItem(name: "@microsoft.graph.conflictBehavior", value: "fail")]
        guard let copyURL = components.url else {
            throw RemoteFileSystemError.operationFailed("Failed to build OneDrive copy URL")
        }

        var request = try authorizedRequest(url: copyURL, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": destination.name,
            "parentReference": [
                "id": destinationParent.id,
                "driveId": try currentDriveID(),
            ],
        ])
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.operationFailed("OneDrive copy failed: invalid HTTP response")
        }
        guard http.statusCode == 202 else {
            try check(response: response, data: data, path: source, conflictPath: destination)
            return
        }
        guard let location = http.value(forHTTPHeaderField: "Location"), let monitorURL = URL(string: location) else {
            throw RemoteFileSystemError.operationFailed("OneDrive copy did not return a monitor URL")
        }
        try await waitForCopyCompletion(monitorURL: monitorURL, destination: destination)
    }

    public func setPermissions(_ permissions: UInt16, at path: RemotePath) async throws {
        _ = (permissions, path)
        throw RemoteFileSystemError.unsupported("OneDrive does not support POSIX permissions")
    }

    private func waitForCopyCompletion(
        monitorURL: URL,
        destination: RemotePath
    ) async throws {
        for _ in 0..<Constants.maxCopyPollCount {
            try requireConnected()
            var request = URLRequest(url: monitorURL)
            request.httpMethod = "GET"
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RemoteFileSystemError.operationFailed("OneDrive copy monitor failed: invalid HTTP response")
            }
            if http.statusCode == 202 {
                try await Task.sleep(nanoseconds: Constants.copyPollDelayNanoseconds)
                continue
            }
            guard http.statusCode == 200 else {
                let message = String(data: data, encoding: .utf8) ?? "<empty response body>"
                throw RemoteFileSystemError.operationFailed(
                    "OneDrive copy monitor failed with HTTP \(http.statusCode): \(message)"
                )
            }

            let operation = try JSONDecoder().decode(OneDriveCopyOperation.self, from: data)
            switch operation.status.lowercased() {
            case "completed":
                return
            case "failed":
                if operation.error?.code == "nameAlreadyExists" {
                    throw RemoteFileSystemError.alreadyExists(destination)
                }
                throw RemoteFileSystemError.operationFailed(operation.error?.message ?? "OneDrive copy failed")
            default:
                try await Task.sleep(nanoseconds: Constants.copyPollDelayNanoseconds)
            }
        }

        throw RemoteFileSystemError.operationFailed("Timed out while waiting for OneDrive copy to complete")
    }

    private func upload(data: Data, to path: RemotePath, conflictBehavior: String = "replace") async throws {
        var request = try authorizedRequest(
            url: try contentURL(for: path, conflictBehavior: conflictBehavior),
            method: "PUT"
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (responseData, response) = try await self.data(for: request)
        try check(response: response, data: responseData, path: path, conflictPath: path)
    }

    private func uploadFile(
        from localFileURL: URL,
        to path: RemotePath,
        conflictBehavior: String = "replace"
    ) async throws {
        let parentPath = try requireParentPath(for: path)
        _ = try await driveItem(at: parentPath)
        let fileSize = try localFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if fileSize <= Constants.uploadChunkSize {
            let data = try Data(contentsOf: localFileURL)
            try await upload(data: data, to: path, conflictBehavior: conflictBehavior)
            return
        }

        var uploadRequest = try authorizedRequest(
            url: try uploadSessionURL(for: path),
            method: "POST"
        )
        uploadRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        uploadRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "item": [
                "@microsoft.graph.conflictBehavior": conflictBehavior,
            ],
        ])
        let (uploadData, uploadResponse) = try await data(for: uploadRequest)
        try check(response: uploadResponse, data: uploadData, path: path, conflictPath: path)
        let uploadSession = try JSONDecoder().decode(OneDriveUploadSession.self, from: uploadData)
        guard let chunkUploadURL = URL(string: uploadSession.uploadUrl),
              let scheme = chunkUploadURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              chunkUploadURL.host != nil else {
            throw RemoteFileSystemError.operationFailed(
                "OneDrive upload failed: invalid upload session URL for \(path.absoluteString)"
            )
        }

        let fileHandle = try FileHandle(forReadingFrom: localFileURL)
        defer { try? fileHandle.close() }

        var offset = 0
        while offset < fileSize {
            try requireConnected()
            let remaining = fileSize - offset
            let chunkSize = min(Constants.uploadChunkSize, remaining)
            let chunk = try fileHandle.read(upToCount: chunkSize) ?? Data()
            guard !chunk.isEmpty else {
                throw RemoteFileSystemError.operationFailed(
                    "OneDrive upload failed: unexpected EOF while reading \(localFileURL.path) at offset \(offset) of \(fileSize); the file may have been modified during upload"
                )
            }

            var chunkRequest = URLRequest(url: chunkUploadURL)
            chunkRequest.httpMethod = "PUT"
            chunkRequest.setValue("\(chunk.count)", forHTTPHeaderField: "Content-Length")
            chunkRequest.setValue(
                "bytes \(offset)-\(offset + chunk.count - 1)/\(fileSize)",
                forHTTPHeaderField: "Content-Range"
            )
            let (chunkData, chunkResponse) = try await session.upload(for: chunkRequest, from: chunk)
            guard let http = chunkResponse as? HTTPURLResponse else {
                throw RemoteFileSystemError.operationFailed("OneDrive upload failed: invalid HTTP response")
            }
            switch http.statusCode {
            case 200, 201, 202:
                offset += chunk.count
            default:
                let message = String(data: chunkData, encoding: .utf8) ?? "<empty response body>"
                throw RemoteFileSystemError.operationFailed(
                    "OneDrive upload failed with HTTP \(http.statusCode): \(message)"
                )
            }
        }
    }

    private func drive(usingToken token: String) async throws -> OneDriveDrive {
        var request = URLRequest(url: URL(string: "\(Constants.graphBase)/me/drive")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteFileSystemError.connectionFailed("OneDrive drive lookup failed: invalid HTTP response")
        }
        switch http.statusCode {
        case 200:
            return try JSONDecoder().decode(OneDriveDrive.self, from: data)
        case 401:
            throw OneDriveHTTPError(statusCode: http.statusCode, message: "Unauthorized")
        default:
            let message = String(data: data, encoding: .utf8) ?? "<empty response body>"
            throw RemoteFileSystemError.connectionFailed(
                "OneDrive drive lookup failed with HTTP \(http.statusCode): \(message)"
            )
        }
    }

    private func refreshAccessToken() async throws {
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
        accessToken = updatedCredential.token
    }

    private func initialAccessToken() async throws -> String {
        if let token = credential.token, !token.isEmpty {
            return token
        }
        guard credential.password?.isEmpty == false else {
            throw RemoteFileSystemError.authenticationFailed
        }
        do {
            try await refreshAccessToken()
            return try currentToken()
        } catch {
            throw RemoteFileSystemError.authenticationFailed
        }
    }

    private func driveItem(at path: RemotePath) async throws -> OneDriveDriveItem {
        if path.isRoot {
            var request = try authorizedRequest(url: URL(string: "\(Constants.graphBase)/me/drive/root")!, method: "GET")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await data(for: request)
            try check(response: response, data: data, path: path)
            return try JSONDecoder().decode(OneDriveDriveItem.self, from: data)
        }

        var request = try authorizedRequest(url: try itemURL(for: path), method: "GET")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await data(for: request)
        try check(response: response, data: data, path: path)
        return try JSONDecoder().decode(OneDriveDriveItem.self, from: data)
    }

    private func ensureAbsent(_ path: RemotePath) async throws {
        do {
            _ = try await driveItem(at: path)
            throw RemoteFileSystemError.alreadyExists(path)
        } catch RemoteFileSystemError.notFound {
            return
        }
    }

    private func requireParentPath(for path: RemotePath) throws -> RemotePath {
        guard let parent = path.parent else {
            throw RemoteFileSystemError.operationFailed("Path has no parent: \(path.absoluteString)")
        }
        return parent
    }

    private func currentToken() throws -> String {
        guard let token = accessToken, !token.isEmpty else {
            throw RemoteFileSystemError.notConnected
        }
        return token
    }

    private func resetConnectionState() {
        accessToken = nil
        driveID = nil
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

    private func requireConnected() throws {
        _ = try currentToken()
    }

    private func requireOAuthProvider() throws -> OneDriveOAuthProvider {
        if let oauthProvider {
            return oauthProvider
        }
        if let oauthProviderLoadError {
            throw oauthProviderLoadError
        }
        throw RemoteFileSystemError.operationFailed(
            "OneDrive OAuth provider is unavailable. OneDriveOAuthProvider.builtIn() failed and no valid clientID/redirectURI are available."
        )
    }

    private func currentDriveID() throws -> String {
        if let driveID {
            return driveID
        }
        throw RemoteFileSystemError.notConnected
    }

    private func authorizedRequest(url: URL, method: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(try currentToken())", forHTTPHeaderField: "Authorization")
        return request
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try requireConnected()
        let result = try await session.data(for: request)
        if let http = result.1 as? HTTPURLResponse, http.statusCode == 401 {
            try requireConnected()
            do {
                try await refreshAccessToken()
                var retried = request
                retried.setValue("Bearer \(try currentToken())", forHTTPHeaderField: "Authorization")
                let retriedResult = try await session.data(for: retried)
                if let retriedHTTP = retriedResult.1 as? HTTPURLResponse,
                   retriedHTTP.statusCode == 401 {
                    resetConnectionState()
                    throw RemoteFileSystemError.authenticationFailed
                }
                return retriedResult
            } catch {
                resetConnectionState()
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
            throw OneDriveHTTPError(statusCode: http.statusCode, message: graphError(from: data).message)
        case 404:
            if let path {
                throw RemoteFileSystemError.notFound(path)
            }
            throw OneDriveHTTPError(statusCode: http.statusCode, message: graphError(from: data).message)
        case 409:
            if let conflictPath {
                throw RemoteFileSystemError.alreadyExists(conflictPath)
            }
            throw RemoteFileSystemError.operationFailed(graphError(from: data).message)
        default:
            throw RemoteFileSystemError.operationFailed(
                "OneDrive API HTTP \(http.statusCode): \(graphError(from: data).message)"
            )
        }
    }

    private func graphError(from data: Data) -> OneDriveGraphErrorBody {
        (try? JSONDecoder().decode(OneDriveGraphErrorEnvelope.self, from: data).error)
            ?? OneDriveGraphErrorBody(code: "unknown", message: String(data: data, encoding: .utf8) ?? "Unknown OneDrive error")
    }

    private func itemURL(for path: RemotePath) throws -> URL {
        if path.isRoot {
            return URL(string: "\(Constants.graphBase)/me/drive/root")!
        }
        return URL(string: "\(Constants.graphBase)/me/drive/root:/\(Self.encode(path))")!
    }

    private func childrenURL(for path: RemotePath) throws -> URL {
        if path.isRoot {
            return URL(string: "\(Constants.graphBase)/me/drive/root/children")!
        }
        return URL(string: "\(Constants.graphBase)/me/drive/root:/\(Self.encode(path)):/children")!
    }

    private func contentURL(for path: RemotePath, conflictBehavior: String? = nil) throws -> URL {
        let url = URL(string: "\(Constants.graphBase)/me/drive/root:/\(Self.encode(path)):/content")!
        guard let conflictBehavior else {
            return url
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RemoteFileSystemError.operationFailed("Failed to build OneDrive content URL")
        }
        components.queryItems = [
            URLQueryItem(name: "@microsoft.graph.conflictBehavior", value: conflictBehavior),
        ]
        guard let conflictURL = components.url else {
            throw RemoteFileSystemError.operationFailed("Failed to build OneDrive content URL")
        }
        return conflictURL
    }

    private func uploadSessionURL(for path: RemotePath) throws -> URL {
        URL(string: "\(Constants.graphBase)/me/drive/root:/\(Self.encode(path)):/createUploadSession")!
    }

    private func itemByIDURL(_ id: String) -> URL {
        URL(string: "\(Constants.graphBase)/me/drive/items/\(id)")!
    }

    private static func encode(_ path: RemotePath) -> String {
        path.components.map { component in
            component.addingPercentEncoding(withAllowedCharacters: encodedPathAllowedCharacters) ?? component
        }.joined(separator: "/")
    }

    fileprivate static func parseISO8601(_ value: String?) -> Date? {
        guard let value else { return nil }
        return isoFormatterWithFractionalSeconds.date(from: value) ?? isoFormatterFallback.date(from: value)
    }
}

private struct OneDriveDrive: Decodable {
    let id: String
}

private struct OneDriveChildrenResponse: Decodable {
    let value: [OneDriveDriveItem]
    let nextLink: String?

    enum CodingKeys: String, CodingKey {
        case value
        case nextLink = "@odata.nextLink"
    }
}

private struct OneDriveDriveItem: Decodable {
    struct FolderFacet: Decodable {}
    struct FileFacet: Decodable {}

    let id: String
    let name: String
    let size: UInt64?
    let folder: FolderFacet?
    let file: FileFacet?
    let createdDateTime: String?
    let lastModifiedDateTime: String?

    var isDirectory: Bool { folder != nil }
    var isFile: Bool { file != nil }
    var remoteItemType: RemoteItemType { isDirectory ? .directory : .file }
    var createdDate: Date? { OneDriveFileSystem.parseISO8601(createdDateTime) }
    var lastModifiedDate: Date? { OneDriveFileSystem.parseISO8601(lastModifiedDateTime) }
}

private struct OneDriveUploadSession: Decodable {
    let uploadUrl: String

    enum CodingKeys: String, CodingKey {
        case uploadUrl
    }
}

private struct OneDriveCopyOperation: Decodable {
    struct OperationError: Decodable {
        let code: String
        let message: String
    }

    let status: String
    let error: OperationError?
}

private struct OneDriveGraphErrorEnvelope: Decodable {
    let error: OneDriveGraphErrorBody
}

private struct OneDriveGraphErrorBody: Decodable {
    let code: String
    let message: String
}

private struct OneDriveHTTPError: Error {
    let statusCode: Int
    let message: String
}
