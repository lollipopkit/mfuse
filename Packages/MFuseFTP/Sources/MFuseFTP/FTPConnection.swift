import Foundation
import NIO
import NIOFoundationCompat
import NIOSSL

/// Low-level FTP client built on SwiftNIO.
/// Handles control connection commands and passive data connections.
final class FTPConnection: @unchecked Sendable {

    private static let connectionTimeout: TimeAmount = .seconds(10)

    private let host: String
    private let port: Int
    private let useTLS: Bool
    private let group: EventLoopGroup
    private let channelLock = NSLock()
    private var channel: Channel?

    init(host: String, port: Int, useTLS: Bool) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.group = MultiThreadedEventLoopGroup.singleton
    }

    // MARK: - Connect / Disconnect

    func connect() async throws {
        let handler = FTPResponseHandler()
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                if self.useTLS {
                    do {
                        let sslHandler = try self.makeTLSHandler(serverHostname: self.host)
                        return channel.pipeline.addHandlers([
                            sslHandler,
                            ByteToMessageHandler(FTPLineDecoder()),
                            handler
                        ])
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                return channel.pipeline.addHandlers([
                    ByteToMessageHandler(FTPLineDecoder()),
                    handler
                ])
            }

        let connectedChannel = try await waitForFuture(
            bootstrap.connect(host: host, port: port)
        )
        setChannel(connectedChannel)

        // Read welcome banner
        let welcome = try await handler.readResponse()
        guard welcome.code >= 200 && welcome.code < 400 else {
            throw FTPError.connectionFailed("Server rejected connection: \(welcome.text)")
        }
    }

    func close() async throws {
        let channel = takeChannel()
        try await channel?.close()
    }

    // MARK: - Command Execution

    func sendCommand(_ command: String) async throws -> FTPResponse {
        guard let channel = currentChannel() else { throw FTPError.notConnected }
        var buffer = channel.allocator.buffer(capacity: command.utf8.count + 2)
        buffer.writeString(command + "\r\n")
        try await channel.writeAndFlush(buffer)
        return try await readResponse()
    }

    func readResponse() async throws -> FTPResponse {
        guard let channel = currentChannel() else { throw FTPError.notConnected }
        let handler = try await channel.pipeline.handler(type: FTPResponseHandler.self).get()
        return try await handler.readResponse()
    }

    // MARK: - Data Connection (Passive Mode)

    func openDataConnection() async throws -> (Channel, FTPDataHandler) {
        // Enter passive mode
        let response = try await sendCommand("PASV")
        guard response.code == 227 else {
            throw FTPError.unexpectedResponse(response)
        }

        let (pasvHost, dataPort) = try parsePASV(response.text)
        let dataHost = normalizedDataConnectionHost(pasvHost)
        let dataHandler = FTPDataHandler()
        var tlsHandler: NIOSSLClientHandler?

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                if self.useTLS {
                    do {
                        let handler = try self.makeTLSHandler(serverHostname: dataHost)
                        tlsHandler = handler
                        return channel.pipeline.addHandlers([
                            handler,
                            dataHandler
                        ])
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                return channel.pipeline.addHandler(dataHandler)
            }

        let dataChannel = try await waitForFuture(
            bootstrap.connect(host: dataHost, port: dataPort)
        )
        if let tlsHandler {
            do {
                try await waitForFuture(tlsHandler.handshakeCompletedFuture)
            } catch {
                try await dataChannel.close()
                throw error
            }
        }
        return (dataChannel, dataHandler)
    }

    private func makeTLSHandler(serverHostname: String) throws -> NIOSSLClientHandler {
        let sslContext = try NIOSSLContext(configuration: .makeClientConfiguration())
        return try NIOSSLClientHandler(context: sslContext, serverHostname: serverHostname)
    }

    private func waitForFuture<T>(_ future: EventLoopFuture<T>) async throws -> T {
        let timeoutPromise = future.eventLoop.makePromise(of: T.self)
        var didTimeOut = false
        let timeoutTask = future.eventLoop.scheduleTask(in: Self.connectionTimeout) {
            didTimeOut = true
            timeoutPromise.fail(FTPError.connectionTimedOut)
        }

        future.whenComplete { result in
            timeoutTask.cancel()

            switch result {
            case .success(let value):
                if didTimeOut {
                    if let channel = value as? Channel {
                        channel.close(promise: nil)
                    }
                    return
                }
                timeoutPromise.succeed(value)
            case .failure(let error):
                guard !didTimeOut else { return }
                timeoutPromise.fail(error)
            }
        }

        return try await timeoutPromise.futureResult.get()
    }

    // MARK: - PASV Parser

    private func parsePASV(_ text: String) throws -> (String, Int) {
        // Format: "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)"
        guard let start = text.firstIndex(of: "("),
              let end = text.firstIndex(of: ")") else {
            throw FTPError.protocolError("Cannot parse PASV response: \(text)")
        }
        let inner = text[text.index(after: start)..<end]
        let parts = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 6 else {
            throw FTPError.protocolError("Invalid PASV numbers: \(text)")
        }
        let host = "\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])"
        let port = parts[4] * 256 + parts[5]
        return (host, port)
    }

    private func normalizedDataConnectionHost(_ pasvHost: String) -> String {
        guard let controlHost = currentChannel()?.remoteAddress?.ipAddress else {
            return pasvHost
        }
        return pasvHost == controlHost ? pasvHost : controlHost
    }

    private func currentChannel() -> Channel? {
        channelLock.lock()
        defer { channelLock.unlock() }
        return channel
    }

    private func setChannel(_ channel: Channel?) {
        channelLock.lock()
        self.channel = channel
        channelLock.unlock()
    }

    private func takeChannel() -> Channel? {
        channelLock.lock()
        let channel = self.channel
        self.channel = nil
        channelLock.unlock()
        return channel
    }
}

// MARK: - FTP Response

struct FTPResponse {
    let code: Int
    let text: String
}

// MARK: - Line Decoder

/// Decodes FTP control connection lines (terminated by \r\n).
final class FTPLineDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let crlfRange = buffer.readableBytesView.firstRange(of: [UInt8(ascii: "\r"), UInt8(ascii: "\n")]) else {
            return .needMoreData
        }
        let length = crlfRange.startIndex - buffer.readableBytesView.startIndex
        let line = buffer.readSlice(length: length)!
        buffer.moveReaderIndex(forwardBy: 2) // skip \r\n
        context.fireChannelRead(wrapInboundOut(line))
        return .continue
    }
}

// MARK: - Response Handler

/// Accumulates FTP response lines and provides async reading.
final class FTPResponseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var pendingResponses: [FTPResponse] = []
    private var continuations: [CheckedContinuation<FTPResponse, Error>] = []
    private var terminalError: Error?
    private var multilineCode: Int?
    private var multilineText = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let line = buffer.readString(length: buffer.readableBytes) else { return }

        // FTP multiline: "123-text" ... "123 text"
        if line.count >= 4 {
            let codeStr = String(line.prefix(3))
            let separator = line[line.index(line.startIndex, offsetBy: 3)]

            if let code = Int(codeStr) {
                if separator == "-" {
                    // Start or continuation of multiline
                    multilineCode = code
                    multilineText += line + "\n"
                    return
                } else if separator == " " {
                    if let mlCode = multilineCode, mlCode == code {
                        // End of multiline response
                        multilineText += line
                        let response = FTPResponse(code: code, text: multilineText)
                        multilineCode = nil
                        multilineText = ""
                        enqueue(response)
                        return
                    } else {
                        // Single-line response
                        let response = FTPResponse(code: code, text: line)
                        enqueue(response)
                        return
                    }
                }
            }
        }

        // Continuation of multiline if active
        if multilineCode != nil {
            multilineText += line + "\n"
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let continuations: [CheckedContinuation<FTPResponse, Error>]

        lock.lock()
        terminalError = error
        continuations = self.continuations
        self.continuations.removeAll()
        lock.unlock()

        continuations.forEach { $0.resume(throwing: error) }
    }

    func readResponse() async throws -> FTPResponse {
        try await withCheckedThrowingContinuation { cont in
            let result: Result<FTPResponse, Error>?

            lock.lock()
            if let response = pendingResponses.first {
                pendingResponses.removeFirst()
                result = .success(response)
            } else if let error = terminalError {
                result = .failure(error)
            } else {
                continuations.append(cont)
                result = nil
            }
            lock.unlock()

            if let result {
                cont.resume(with: result)
            }
        }
    }

    private func enqueue(_ response: FTPResponse) {
        let continuation: CheckedContinuation<FTPResponse, Error>?

        lock.lock()
        if !self.continuations.isEmpty {
            continuation = self.continuations.removeFirst()
        } else {
            pendingResponses.append(response)
            continuation = nil
        }
        lock.unlock()

        continuation?.resume(returning: response)
    }
}

// MARK: - Data Handler

/// Collects data from an FTP data connection.
final class FTPDataHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var buffer = Data()
    private var continuations: [CheckedContinuation<Data, Error>] = []
    private var completed = false
    private var terminalError: Error?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            lock.lock()
            buffer.append(contentsOf: bytes)
            lock.unlock()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let result: Result<Data, Error>?
        let continuations: [CheckedContinuation<Data, Error>]

        lock.lock()
        completed = true
        continuations = self.continuations
        self.continuations.removeAll()
        if let error = terminalError {
            result = .failure(error)
        } else {
            result = .success(buffer)
        }
        lock.unlock()

        guard let result else { return }
        continuations.forEach { $0.resume(with: result) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        let continuations: [CheckedContinuation<Data, Error>]

        lock.lock()
        terminalError = error
        completed = true
        continuations = self.continuations
        self.continuations.removeAll()
        lock.unlock()

        continuations.forEach { $0.resume(throwing: error) }
    }

    func collectData() async throws -> Data {
        return try await withCheckedThrowingContinuation { cont in
            let result: Result<Data, Error>?

            lock.lock()
            if completed {
                if let error = terminalError {
                    result = .failure(error)
                } else {
                    result = .success(buffer)
                }
            } else {
                continuations.append(cont)
                result = nil
            }
            lock.unlock()

            if let result {
                cont.resume(with: result)
            }
        }
    }
}

// MARK: - Errors

enum FTPError: Error, LocalizedError {
    case notConnected
    case connectionTimedOut
    case connectionFailed(String)
    case authenticationFailed
    case unexpectedResponse(FTPResponse)
    case protocolError(String)
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to FTP server"
        case .connectionTimedOut: return "FTP connection timed out"
        case .connectionFailed(let msg): return "FTP connection failed: \(msg)"
        case .authenticationFailed: return "FTP authentication failed"
        case .unexpectedResponse(let r): return "Unexpected FTP response \(r.code): \(r.text)"
        case .protocolError(let msg): return "FTP protocol error: \(msg)"
        case .transferFailed(let msg): return "FTP transfer failed: \(msg)"
        }
    }
}
