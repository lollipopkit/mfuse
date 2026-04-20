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
        guard let url = URL(string: "\(scheme)://\(config.host):\(config.port)\(config.remotePath)") else {
            throw RemoteFileSystemError.connectionFailed("Invalid WebDAV URL")
        }
        self.baseURL = url

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

        self.session = URLSession(configuration: sessionConfig)

        // Test connectivity with PROPFIND on root
        _ = try await propfind(url: url, depth: "0")
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
        let parentHref = url.path
        return resources.compactMap { res -> RemoteItem? in
            let resPath = cleanHref(res.href)
            guard resPath != cleanHref(parentHref) else { return nil }
            let name = extractName(from: res.href, isCollection: res.isCollection)
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

    public func createFile(at path: RemotePath, data: Data) async throws {
        // WebDAV PUT creates or overwrites; check existence first
        let url = try resourceURL(for: path)
        let session = try requireSession()

        // Check if exists with HEAD
        var headReq = URLRequest(url: url)
        headReq.httpMethod = "HEAD"
        let (_, headResp) = try await session.data(for: headReq)
        if let http = headResp as? HTTPURLResponse, http.statusCode == 200 {
            throw RemoteFileSystemError.alreadyExists(path)
        }

        try await writeFile(at: path, data: data)
    }

    // MARK: - Mutations

    public func createDirectory(at path: RemotePath) async throws {
        let url = try resourceURL(for: path, isDirectory: true)
        let session = try requireSession()
        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        let (_, response) = try await session.data(for: request)
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
        if path.isRoot { return base }
        let relative = path.components.joined(separator: "/")
        var urlString = base.absoluteString
        if !urlString.hasSuffix("/") { urlString += "/" }
        urlString += relative
        if isDirectory && !urlString.hasSuffix("/") { urlString += "/" }
        guard let url = URL(string: urlString) else {
            throw RemoteFileSystemError.operationFailed("Invalid URL for path: \(path)")
        }
        return url
    }

    private func propfind(url: URL, depth: String) async throws -> [WebDAVResource] {
        let session = try requireSession()
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
                if http.statusCode == 401 || http.statusCode == 403 {
                    throw RemoteFileSystemError.authenticationFailed
                }
                throw RemoteFileSystemError.connectionFailed("HTTP \(http.statusCode)")
            }
        }

        let parser = WebDAVXMLParser()
        return parser.parse(data: data)
    }

    private func checkHTTPResponse(_ response: URLResponse, path: RemotePath,
                                    acceptCodes: ClosedRange<Int> = 200...299) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard acceptCodes.contains(http.statusCode) || http.statusCode == 207 else {
            switch http.statusCode {
            case 404: throw RemoteFileSystemError.notFound(path)
            case 401, 403: throw RemoteFileSystemError.authenticationFailed
            case 405: throw RemoteFileSystemError.unsupported("Method not allowed")
            case 409: throw RemoteFileSystemError.operationFailed("Conflict (parent may not exist)")
            default:
                throw RemoteFileSystemError.operationFailed("HTTP \(http.statusCode)")
            }
        }
    }

    private func cleanHref(_ href: String) -> String {
        var h = href
        if h.hasSuffix("/") { h = String(h.dropLast()) }
        // Remove percent encoding for comparison
        return h.removingPercentEncoding ?? h
    }

    private func extractName(from href: String, isCollection: Bool) -> String {
        var h = href
        if h.hasSuffix("/") { h = String(h.dropLast()) }
        h = h.removingPercentEncoding ?? h
        return (h as NSString).lastPathComponent
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
