import Foundation
import MFuseCore

public final class MockURLProtocol: URLProtocol {
    public enum Response {
        case http(status: Int, body: Data, headers: [String: String] = [:])
    }

    public typealias Handler = @Sendable (URLRequest) throws -> Response

    public static let sessionHeader = "X-MFuse-Mock-Session"

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    public static func register(handler: @escaping Handler, for token: String) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    public static func unregister(token: String) {
        lock.lock()
        handlers[token] = nil
        lock.unlock()
    }

    override public static func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: sessionHeader) != nil
    }

    override public static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override public func startLoading() {
        guard let token = request.value(forHTTPHeaderField: Self.sessionHeader),
              let handler = Self.handler(for: token) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            switch try handler(request) {
            case .http(let status, let body, let headers):
                guard let url = request.url,
                      let response = HTTPURLResponse(
                        url: url,
                        statusCode: status,
                        httpVersion: nil,
                        headerFields: headers
                      ) else {
                    client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                    return
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override public func stopLoading() {}

    private static func handler(for token: String) -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[token]
    }
}

public final class MockSessionHandlerCleaner: NSObject, URLSessionDelegate {
    private let token: String

    public init(token: String) {
        self.token = token
    }

    deinit {
        MockURLProtocol.unregister(token: token)
    }
}

public actor CredentialUpdateRecorder {
    public private(set) var lastCredential: Credential?

    public init() {}

    public func record(_ credential: Credential) {
        lastCredential = credential
    }
}

public struct TestFailure: LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
