import Foundation
import Darwin
import NIO
import NIOFoundationCompat
import NIOSSL

/// Low-level FTP client built on SwiftNIO.
/// Handles control connection commands and passive data connections.
final class FTPConnection: @unchecked Sendable {

    static let operationTimeout: TimeAmount = .seconds(10)

    private let host: String
    private let port: Int
    private let useTLS: Bool
    private let group: EventLoopGroup
    private let commandGate = CommandGate()
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

        do {
            // Read welcome banner
            let welcome = try await handler.readResponse(timeout: Self.operationTimeout)
            guard welcome.code >= 200 && welcome.code < 400 else {
                throw FTPError.connectionFailed("Server rejected connection: \(welcome.text)")
            }
        } catch {
            try? await connectedChannel.close()
            setChannel(nil)
            throw error
        }

        setChannel(connectedChannel)
    }

    func close() async throws {
        let channel = takeChannel()
        try await channel?.close()
    }

    // MARK: - Command Execution

    func sendCommand(_ command: String) async throws -> FTPResponse {
        try await commandGate.withLock {
            guard let channel = currentChannel() else { throw FTPError.notConnected }
            var buffer = channel.allocator.buffer(capacity: command.utf8.count + 2)
            buffer.writeString(command + "\r\n")
            try await channel.writeAndFlush(buffer)
            return try await readResponseUnlocked()
        }
    }

    func readResponse() async throws -> FTPResponse {
        try await commandGate.withLock {
            try await readResponseUnlocked()
        }
    }

    private func readResponseUnlocked() async throws -> FTPResponse {
        guard let channel = currentChannel() else { throw FTPError.notConnected }
        let handler = try await channel.pipeline.handler(type: FTPResponseHandler.self).get()
        return try await handler.readResponse(timeout: Self.operationTimeout)
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
                        let handler = try self.makeTLSHandler(serverHostname: pasvHost)
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
        let timeoutTask = future.eventLoop.scheduleTask(in: Self.operationTimeout) {
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
        guard parts.allSatisfy({ (0...255).contains($0) }) else {
            throw FTPError.protocolError("Invalid PASV numbers or port out of range: \(text)")
        }
        let host = "\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3])"
        let port = parts[4] * 256 + parts[5]
        guard (1...65535).contains(port) else {
            throw FTPError.protocolError("Invalid PASV numbers or port out of range: \(text)")
        }
        return (host, port)
    }

    private func normalizedDataConnectionHost(_ pasvHost: String) -> String {
        guard let controlHost = currentChannel()?.remoteAddress?.ipAddress else {
            return pasvHost
        }
        return isUnusablePASVAddress(pasvHost) ? controlHost : pasvHost
    }

    private func isUnusablePASVAddress(_ host: String) -> Bool {
        if let ipv4 = ipv4Octets(for: host) {
            return isUnusableIPv4(ipv4)
        }
        if let ipv6 = ipv6Words(for: host) {
            return isUnusableIPv6(ipv6)
        }
        return false
    }

    private func ipv4Octets(for host: String) -> [UInt8]? {
        var address = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else {
            return nil
        }

        let value = UInt32(bigEndian: address.s_addr)
        return [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
    }

    private func ipv6Words(for host: String) -> [UInt16]? {
        var address = in6_addr()
        guard host.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
            return nil
        }

        return withUnsafeBytes(of: address.__u6_addr.__u6_addr16) { rawBuffer in
            rawBuffer.bindMemory(to: UInt16.self).map { UInt16(bigEndian: $0) }
        }
    }

    private func isUnusableIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return false }
        let first = octets[0]
        let second = octets[1]

        if octets == [0, 0, 0, 0] { return true }                 // unspecified
        if first == 10 { return true }                            // RFC1918
        if first == 127 { return true }                           // loopback
        if first == 169 && second == 254 { return true }          // link-local
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        if first == 100 && (64...127).contains(second) { return true } // CGNAT
        if first == 198 && (second == 18 || second == 19) { return true }
        if first == 192 && second == 0 && octets[2] == 2 { return true } // TEST-NET-1
        if first == 198 && second == 51 && octets[2] == 100 { return true } // TEST-NET-2
        if first == 203 && second == 0 && octets[2] == 113 { return true } // TEST-NET-3
        if first >= 224 { return true }                           // multicast/reserved
        return false
    }

    private func isUnusableIPv6(_ words: [UInt16]) -> Bool {
        guard words.count == 8 else { return false }
        if words.allSatisfy({ $0 == 0 }) { return true }          // unspecified
        if words.dropLast().allSatisfy({ $0 == 0 }) && words.last == 1 { return true } // loopback

        let first = words[0]
        if (first & 0xfe00) == 0xfc00 { return true }             // ULA fc00::/7
        if (first & 0xffc0) == 0xfe80 { return true }             // link-local fe80::/10
        if (first & 0xff00) == 0xff00 { return true }             // multicast ff00::/8
        if first == 0x2001 && words[1] == 0x0db8 { return true } // documentation 2001:db8::/32
        return false
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

private actor CommandGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        await lock()
        defer { unlock() }
        return try await operation()
    }

    private func lock() async {
        guard isLocked else {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func unlock() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            isLocked = false
        }
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

    private struct PendingContinuation {
        let id: UUID
        let continuation: CheckedContinuation<FTPResponse, Error>
    }

    private let lock = NSLock()
    private var pendingResponses: [FTPResponse] = []
    private var continuations: [PendingContinuation] = []
    private var terminalError: Error?
    private var multilineCode: Int?
    private var multilineText = ""
    private var context: ChannelHandlerContext?

    func handlerAdded(context: ChannelHandlerContext) {
        lock.lock()
        self.context = context
        lock.unlock()
    }

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
        pendingResponses.removeAll()
        continuations = self.continuations.map(\.continuation)
        self.continuations.removeAll()
        lock.unlock()

        continuations.forEach { $0.resume(throwing: error) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let error = FTPError.connectionFailed("FTP control connection closed")
        let continuations: [CheckedContinuation<FTPResponse, Error>]

        lock.lock()
        terminalError = error
        pendingResponses.removeAll()
        continuations = self.continuations.map(\.continuation)
        self.continuations.removeAll()
        lock.unlock()

        continuations.forEach { $0.resume(throwing: error) }
    }

    func readResponse(timeout: TimeAmount? = nil) async throws -> FTPResponse {
        try await withCheckedThrowingContinuation { cont in
            let result: Result<FTPResponse, Error>?
            let waiterID = UUID()
            var shouldScheduleTimeout = false

            lock.lock()
            if let response = pendingResponses.first {
                pendingResponses.removeFirst()
                result = .success(response)
            } else if let error = terminalError {
                result = .failure(error)
            } else {
                continuations.append(PendingContinuation(id: waiterID, continuation: cont))
                shouldScheduleTimeout = timeout != nil
                result = nil
            }
            lock.unlock()

            if shouldScheduleTimeout, let timeout {
                scheduleTimeout(for: waiterID, timeout: timeout)
            }
            if let result {
                cont.resume(with: result)
            }
        }
    }

    private func enqueue(_ response: FTPResponse) {
        let continuation: CheckedContinuation<FTPResponse, Error>?
        let shouldDrop: Bool

        lock.lock()
        if terminalError != nil {
            shouldDrop = true
            continuation = nil
        } else if !self.continuations.isEmpty {
            shouldDrop = false
            continuation = self.continuations.removeFirst().continuation
        } else {
            shouldDrop = false
            pendingResponses.append(response)
            continuation = nil
        }
        lock.unlock()

        guard !shouldDrop else { return }
        continuation?.resume(returning: response)
    }

    private func scheduleTimeout(for waiterID: UUID, timeout: TimeAmount) {
        let nanoseconds = max(timeout.nanoseconds, 0)
        let deadline = DispatchTime.now() + .nanoseconds(Int(nanoseconds))
        DispatchQueue.global().asyncAfter(deadline: deadline) { [weak self] in
            self?.failContinuationIfPending(id: waiterID, error: FTPError.connectionTimedOut)
        }
    }

    private func failContinuationIfPending(id: UUID, error: Error) {
        let continuations: [CheckedContinuation<FTPResponse, Error>]
        let context: ChannelHandlerContext?

        lock.lock()
        if let index = self.continuations.firstIndex(where: { $0.id == id }) {
            terminalError = error
            pendingResponses.removeAll()
            var pending = self.continuations
            let timedOut = pending.remove(at: index)
            continuations = [timedOut.continuation] + pending.map(\.continuation)
            context = self.context
            self.continuations.removeAll()
        } else {
            continuations = []
            context = nil
        }
        lock.unlock()

        continuations.forEach { $0.resume(throwing: error) }
        context?.close(promise: nil)
    }
}

// MARK: - Data Handler

/// Collects data from an FTP data connection.
final class FTPDataHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private struct PendingContinuation {
        let id: UUID
        let continuation: CheckedContinuation<Data, Error>
    }

    private let lock = NSLock()
    private var buffer = Data()
    private var continuations: [PendingContinuation] = []
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
        continuations = self.continuations.map(\.continuation)
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
        continuations = self.continuations.map(\.continuation)
        self.continuations.removeAll()
        lock.unlock()

        continuations.forEach { $0.resume(throwing: error) }
    }

    func collectData(timeout: TimeAmount? = nil) async throws -> Data {
        return try await withCheckedThrowingContinuation { cont in
            let result: Result<Data, Error>?
            let waiterID = UUID()
            var shouldScheduleTimeout = false

            lock.lock()
            if completed {
                if let error = terminalError {
                    result = .failure(error)
                } else {
                    result = .success(buffer)
                }
            } else {
                continuations.append(PendingContinuation(id: waiterID, continuation: cont))
                shouldScheduleTimeout = timeout != nil
                result = nil
            }
            lock.unlock()

            if shouldScheduleTimeout, let timeout {
                scheduleTimeout(for: waiterID, timeout: timeout)
            }
            if let result {
                cont.resume(with: result)
            }
        }
    }

    private func scheduleTimeout(for waiterID: UUID, timeout: TimeAmount) {
        let nanoseconds = max(timeout.nanoseconds, 0)
        let deadline = DispatchTime.now() + .nanoseconds(Int(nanoseconds))
        DispatchQueue.global().asyncAfter(deadline: deadline) { [weak self] in
            self?.failContinuationIfPending(id: waiterID, error: FTPError.connectionTimedOut)
        }
    }

    private func failContinuationIfPending(id: UUID, error: Error) {
        let continuation: CheckedContinuation<Data, Error>?

        lock.lock()
        if let index = continuations.firstIndex(where: { $0.id == id }) {
            continuation = continuations.remove(at: index).continuation
        } else {
            continuation = nil
        }
        lock.unlock()

        continuation?.resume(throwing: error)
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
