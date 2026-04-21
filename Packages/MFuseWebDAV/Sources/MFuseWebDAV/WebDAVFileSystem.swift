import Foundation
import MFuseCore

/// WebDAV implementation of `RemoteFileSystem` using URLSession.
/// Supports both HTTP and HTTPS. Zero third-party dependencies.
public actor WebDAVFileSystem: RemoteFileSystem {

    private let config: ConnectionConfig
    private let credential: Credential
    private var session: URLSession?
    private var baseURL: URL?

    public var isConnected: Bool { session != nil }

    public init(config: ConnectionConfig, credential: Credential) {
        self.config = config
        self.credential = credential
    }

    // MARK: - Config Helpers

    private var useTLS: Bool { config.parameters["tls"] != "false" }

    // MARK: - Lifecycle

    public func connect() async throws {
        let scheme = useTLS ? "https" : "http"
        var components = URLComponents()
        components.scheme = scheme
        components.host = config.host
        components.port = Int(config.port)
        guard let rootURL = components.url else {
            throw RemoteFileSystemError.connectionFailed("Invalid WebDAV URL")
        }
        let url = Self.appendingPathComponents(
            config.remotePath.split(separator: "/").map(String.init),
            to: rootURL,
            isDirectory: true
        )

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30

        // Set up basic auth if not anonymous
        if config.authMethod != .anonymous, let password = credential.password {
            let authString = "\(config.username):\(password)"
            if let authData = authString.data(using: .utf8) {
                let base64 = authData.base64EncodedString()
                sessionConfig.httpAdditionalHeaders = ["Authorization": "Basic \(base64)"]
            }
        }

        let session = URLSession(configuration: sessionConfig)

        do {
            // Test connectivity with PROPFIND on root before committing connection state.
            _ = try await propfind(url: url, depth: "0", session: session)
        } catch {
            session.invalidateAndCancel()
            throw error
        }

        self.baseURL = url
        self.session = session
    }

    public func disconnect() async throws {
        session?.invalidateAndCancel()
        session = nil
        baseURL = nil
    }

    // MARK: - Enumeration

    public func enumerate(at path: RemotePath) async throws -> [RemoteItem] {
        let url = try resourceURL(for: path, isDirectory: true)
        let resources = try await propfind(url: url, depth: "1")

        // First entry is the directory itself; skip it
        let parentHref = cleanHref(url.path)
        return resources.compactMap { res -> RemoteItem? in
            let normalizedHref = normalizeHref(res.href, relativeTo: url)
            let resPath = cleanHref(normalizedHref)
            guard resPath != parentHref else { return nil }
            let name = extractName(from: normalizedHref, isCollection: res.isCollection)
            guard !name.isEmpty else { return nil }
            let childPath = path.appending(name)
            return RemoteItem(
                path: childPath,
                type: res.isCollection ? .directory : .file,
                size: res.contentLength,
                modificationDate: res.lastModified ?? Date()
            )
        }
    }

    public func itemInfo(at path: RemotePath) async throws -> RemoteItem {
        let url = try resourceURL(for: path)
        let resources = try await propfind(url: url, depth: "0")
        guard let res = resources.first else {
            throw RemoteFileSystemError.notFound(path)
        }
        return RemoteItem(
            path: path,
            type: res.isCollection ? .directory : .file,
            size: res.contentLength,
            modificationDate: res.lastModified ?? Date()
        )
    }

    // MARK: - Read

    public func readFile(at path: RemotePath) async throws -> Data {
        let url = try resourceURL(for: path)
        let session = try requireSession()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)
        try checkHTTPResponse(response, path: path)
        return data
    }

    // MARK: - Write

    public func writeFile(at path: RemotePath, data: Data) async throws {
        let url = try resourceURL(for: path)
        let session = try requireSession()
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.data(for: request)
        try checkHTTPResponse(response, path: path, acceptCodes: 200...299)
    }

    public func writeFile(at path: RemotePath, from localFileURL: URL) async throws {
        let url = try resourceURL(for: path)
        let session = try requireSession()
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, fromFile: localFileURL)
        try checkHTTPResponse(response, path: path, acceptCodes: 200...299)
    }

    public func createFile(at path: RemotePath, data: Data) async throws {
        let url = try resourceURL(for: path)
        let session = try requireSession()
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 412 {
            throw RemoteFileSystemError.alreadyExists(path)
        }
        try checkHTTPResponse(response, path: path, acceptCodes: 200...299)
    }

    public func createFile(at path: RemotePath, from localFileURL: URL) async throws {
        let url = try resourceURL(for: path)
        let session = try requireSession()
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("*", forHTTPHeaderField: "If-None-Match")
        let (_, response) = try await session.upload(for: request, fromFile: localFileURL)
        if let http = response as? HTTPURLResponse, http.statusCode == 412 {
            throw RemoteFileSystemError.alreadyExists(path)
        }
        try checkHTTPResponse(response, path: path, acceptCodes: 200...299)
    }

    // MARK: - Mutations

    public func createDirectory(at path: RemotePath) async throws {
        let url = try resourceURL(for: path, isDirectory: true)
        let session = try requireSession()
        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 405 {
            throw RemoteFileSystemError.alreadyExists(path)
        }
        try checkHTTPResponse(response, path: path, acceptCodes: 200...299)
    }

    public func delete(at path: RemotePath) async throws {
        let url = try resourceURL(for: path)
        let session = try requireSession()
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await session.data(for: request)
        try checkHTTPResponse(response, path: path, acceptCodes: 200...299)
    }

    public func move(from source: RemotePath, to destination: RemotePath) async throws {
        let srcURL = try resourceURL(for: source)
        let dstURL = try resourceURL(for: destination)
        let session = try requireSession()
        var request = URLRequest(url: srcURL)
        request.httpMethod = "MOVE"
        request.setValue(dstURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await session.data(for: request)
        try checkHTTPResponse(response, path: source, acceptCodes: 200...299)
    }

    public func copy(from source: RemotePath, to destination: RemotePath) async throws {
        let srcURL = try resourceURL(for: source)
        let dstURL = try resourceURL(for: destination)
        let session = try requireSession()
        var request = URLRequest(url: srcURL)
        request.httpMethod = "COPY"
        request.setValue(dstURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("F", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await session.data(for: request)
        try checkHTTPResponse(response, path: source, acceptCodes: 200...299)
    }

    // MARK: - Helpers

    private func requireSession() throws -> URLSession {
        guard let session = session else {
            throw RemoteFileSystemError.notConnected
        }
        return session
    }

    private func resourceURL(for path: RemotePath, isDirectory: Bool = false) throws -> URL {
        guard let base = baseURL else {
            throw RemoteFileSystemError.notConnected
        }
        if path.isRoot {
            return isDirectory ? Self.normalizedDirectoryURL(base) : base
        }
        return Self.appendingPathComponents(path.components, to: base, isDirectory: isDirectory)
    }

    private static func appendingPathComponents(
        _ pathComponents: [String],
        to baseURL: URL,
        isDirectory: Bool
    ) -> URL {
        let url = pathComponents.reduce(baseURL) { partialURL, component in
            partialURL.appendingPathComponent(component)
        }
        return isDirectory ? normalizedDirectoryURL(url) : url
    }

    private static func normalizedDirectoryURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        if !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        return components.url ?? url
    }

    private func propfind(url: URL, depth: String) async throws -> [WebDAVResource] {
        let session = try requireSession()
        return try await propfind(url: url, depth: depth, session: session)
    }

    private func propfind(url: URL, depth: String, session: URLSession) async throws -> [WebDAVResource] {
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue(depth, forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = propfindBody.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            guard (200...299).contains(http.statusCode) || http.statusCode == 207 else {
                if http.statusCode == 404 {
                    throw RemoteFileSystemError.notFound(RemotePath(url.path))
                }
                if http.statusCode == 401 {
                    throw RemoteFileSystemError.authenticationFailed
                }
                if http.statusCode == 403 {
                    throw RemoteFileSystemError.permissionDenied(RemotePath(url.path))
                }
                throw RemoteFileSystemError.connectionFailed("HTTP \(http.statusCode)")
            }
        }

        let parser = WebDAVXMLParser()
        return parser.parse(data: data)
    }

    private func checkHTTPResponse(
        _ response: URLResponse,
        path: RemotePath,
        acceptCodes: ClosedRange<Int> = 200...299
    ) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard acceptCodes.contains(http.statusCode) || http.statusCode == 207 else {
            switch http.statusCode {
            case 404: throw RemoteFileSystemError.notFound(path)
            case 401: throw RemoteFileSystemError.authenticationFailed
            case 403: throw RemoteFileSystemError.permissionDenied(path)
            case 405: throw RemoteFileSystemError.unsupported("Method not allowed")
            case 409: throw RemoteFileSystemError.operationFailed("Conflict (parent may not exist)")
            default:
                throw RemoteFileSystemError.operationFailed("HTTP \(http.statusCode)")
            }
        }
    }

    private func cleanHref(_ href: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let collapsed = decoded.replacingOccurrences(of: #"\/+"#, with: "/", options: .regularExpression)
        guard collapsed.count > 1, collapsed.hasSuffix("/") else {
            return collapsed
        }
        return String(collapsed.dropLast())
    }

    private func extractName(from href: String, isCollection: Bool) -> String {
        var cleanedHref = href
        if cleanedHref.hasSuffix("/") { cleanedHref = String(cleanedHref.dropLast()) }
        cleanedHref = cleanedHref.removingPercentEncoding ?? cleanedHref
        return (cleanedHref as NSString).lastPathComponent
    }

    private func normalizeHref(_ href: String, relativeTo baseURL: URL) -> String {
        if let resolvedURL = URL(string: href, relativeTo: baseURL)?.absoluteURL {
            return resolvedURL.path
        }
        return href
    }

    private let propfindBody = """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:displayname/>
        <d:resourcetype/>
        <d:getcontentlength/>
        <d:getlastmodified/>
      </d:prop>
    </d:propfind>
    """
}
