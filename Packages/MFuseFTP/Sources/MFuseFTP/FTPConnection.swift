import Foundation
import Darwin
import NIO
import NIOConcurrencyHelpers
import NIOFoundationCompat
import NIOSSL
import NIOTLS

private final class TLSHandshakeCompletionHandler: ChannelInboundHandler, RemovableChannelHandler, Sendable {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<Void>

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case NIOTLS.TLSUserEvent.handshakeCompleted = event {
            promise.succeed(())
            context.pipeline.removeHandler(self, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(FTPError.protocolError("TLS connection closed during handshake"))
        context.fireChannelInactive()
    }
}

/// How an FTP connection is protected with TLS (RFC 4217).
enum FTPSecurity: Sendable, Equatable {
    case none
    /// Connects in plain text and upgrades with `AUTH TLS`: standard FTPS, usually on port 21.
    case explicit
    /// TLS from the first byte: the older FTPS, conventionally on port 990.
    case implicit
}

/// One passive data connection, opened for a single transfer.
struct FTPDataConnection {
    let channel: Channel
    let handler: FTPDataHandler
    /// Completes when the TLS handshake does; `nil` on an unprotected connection.
    fileprivate let handshake: EventLoopFuture<Void>?
}

/// Low-level FTP client built on SwiftNIO.
/// Handles control connection commands and passive data connections.
final class FTPConnection: @unchecked Sendable {

    static let operationTimeout: TimeAmount = .seconds(10)

    private let host: String
    private let port: Int
    private let security: FTPSecurity
    /// Shared by the control and every data connection; `nil` without TLS.
    private let tlsContext: NIOSSLContext?
    private let group: EventLoopGroup
    private let commandGate = CommandGate()
    private let channelLock = NSLock()
    private var channel: Channel?
    /// Set once the server rejects `EPSV`, so later transfers go straight to `PASV`.
    private let epsvRefused = NIOLockedValueBox(false)

    /// `additionalTrustRoots` are trusted on top of the system's roots.
    init(host: String, port: Int, security: FTPSecurity, additionalTrustRoots: [NIOSSLCertificate] = []) throws {
        self.host = host
        self.port = port
        self.security = security
        if security == .none {
            self.tlsContext = nil
        } else {
            var configuration = TLSConfiguration.makeClientConfiguration()
            if !additionalTrustRoots.isEmpty {
                configuration.additionalTrustRoots = [.certificates(additionalTrustRoots)]
            }
            self.tlsContext = try NIOSSLContext(configuration: configuration)
        }
        self.group = MultiThreadedEventLoopGroup.singleton
    }

    // MARK: - Connect / Disconnect

    func connect() async throws {
        try await commandGate.withLock {
            if let existingChannel = currentChannel(), existingChannel.isActive {
                return
            }

            let staleChannel = takeChannel()
            try await staleChannel?.close()

            let handlerPromise = group.next().makePromise(of: FTPResponseHandler.self)
            let bootstrap = ClientBootstrap(group: group)
                .channelOption(.socketOption(.so_reuseaddr), value: 1)
                .channelInitializer { channel in
                    let responseHandler = FTPResponseHandler()
                    handlerPromise.succeed(responseHandler)

                    if self.security == .implicit {
                        do {
                            let sslHandler = try self.makeTLSHandler()
                            try channel.pipeline.syncOperations.addHandler(sslHandler)
                            try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(FTPLineDecoder()))
                            try channel.pipeline.syncOperations.addHandler(responseHandler)
                            return channel.eventLoop.makeSucceededVoidFuture()
                        } catch {
                            handlerPromise.fail(error)
                            return channel.eventLoop.makeFailedFuture(error)
                        }
                    }
                    do {
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(FTPLineDecoder()))
                        try channel.pipeline.syncOperations.addHandler(responseHandler)
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        handlerPromise.fail(error)
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }

            let connectedChannel = try await waitForFuture(
                bootstrap.connect(host: host, port: port)
            )
            let handler = try await waitForFuture(handlerPromise.futureResult)

            do {
                // Read welcome banner
                let welcome = try await handler.readResponse(timeout: Self.operationTimeout)
                guard welcome.code >= 200 && welcome.code < 400 else {
                    throw FTPError.connectionFailed("Server rejected connection: \(welcome.text)")
                }
                if security == .explicit {
                    try await upgradeToTLS(connectedChannel, responses: handler)
                }
            } catch {
                try? await connectedChannel.close()
                throw error
            }

            let previousChannel = replaceChannel(connectedChannel)
            try await previousChannel?.close()
        }
    }

    func close() async throws {
        try await commandGate.withLock {
            let channel = takeChannel()
            do {
                try await channel?.close()
            } catch ChannelError.alreadyClosed {
                // The server closes its end after QUIT; the connection is closed either way.
            }
        }
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

    // MARK: - TLS

    /// `AUTH TLS`, then a TLS handshake over the same connection (RFC 4217 section 4).
    private func upgradeToTLS(_ channel: Channel, responses: FTPResponseHandler) async throws {
        var buffer = channel.allocator.buffer(capacity: 10)
        buffer.writeString("AUTH TLS\r\n")
        try await channel.writeAndFlush(buffer)
        let response = try await responses.readResponse(timeout: Self.operationTimeout)
        guard response.code == 234 else {
            throw FTPError.connectionFailed("Server does not support FTPS (AUTH TLS): \(response.text)")
        }

        let handshake = channel.eventLoop.makePromise(of: Void.self)
        try await channel.eventLoop.submit {
            let sslHandler = try self.makeTLSHandler()
            let pipeline = channel.pipeline.syncOperations
            try pipeline.addHandler(sslHandler, position: .first)
            try pipeline.addHandler(TLSHandshakeCompletionHandler(promise: handshake), position: .after(sslHandler))
        }.get()
        try await waitForFuture(handshake.futureResult)
    }

    /// Every connection, control and data alike, checks the certificate against the host
    /// the user entered: a passive reply carries only an address. An IP address cannot go
    /// in SNI; without a name NIOSSL checks the certificate against the address connected to.
    private func makeTLSHandler() throws -> NIOSSLClientHandler {
        guard let tlsContext else {
            throw FTPError.protocolError("TLS requested on a connection configured without it")
        }
        let serverHostname = Self.isIPAddress(host) ? nil : host
        return try NIOSSLClientHandler(context: tlsContext, serverHostname: serverHostname)
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return host.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }

    // MARK: - Data Connection (Passive Mode)

    /// Opens a passive data connection and sends `command`, which transfers over it.
    ///
    /// Throws `FTPError.unexpectedResponse` when the server refuses the command. On a
    /// protected connection the TLS handshake is awaited only once the server has accepted
    /// the command, since servers start it at that point.
    func beginTransfer(_ command: String) async throws -> FTPDataConnection {
        let data = try await openDataConnection()
        let response: FTPResponse
        do {
            response = try await sendCommand(command)
        } catch {
            try? await data.channel.close()
            throw error
        }
        guard response.code == 125 || response.code == 150 else {
            try? await data.channel.close()
            throw FTPError.unexpectedResponse(response)
        }
        if let handshake = data.handshake {
            do {
                try await waitForFuture(handshake)
            } catch {
                try await abortTransfer(data)
                throw error
            }
        }
        return data
    }

    /// Reads the server's verdict on a transfer whose data connection is done.
    func finishTransfer() async throws {
        let response = try await readResponse()
        guard response.code == 226 || response.code == 250 else {
            throw FTPError.transferFailed(response.text)
        }
    }

    /// Closes the data connection of a failed transfer and consumes the server's reply to
    /// it, so the next command does not take that reply for its own.
    ///
    /// Throws `FTPError.controlConnectionLost` when that reply cannot be read: the reply may
    /// still arrive later, so the control connection can no longer be trusted to pair
    /// commands with their replies.
    func abortTransfer(_ data: FTPDataConnection) async throws {
        try? await data.channel.close()
        do {
            _ = try await readResponse()
        } catch {
            throw FTPError.controlConnectionLost(error.localizedDescription)
        }
    }

    private func openDataConnection() async throws -> FTPDataConnection {
        let (dataHost, dataPort) = try await passiveDataEndpoint()
        let dataHandlerPromise = group.next().makePromise(of: FTPDataHandler.self)
        // The channel initializer runs on the channel's event loop while this function
        // reads the result afterwards, so the handshake future is handed over through a
        // locked box instead of a captured `var`.
        let handshakeFutureBox = NIOLockedValueBox<EventLoopFuture<Void>?>(nil)

        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                let dataHandler = FTPDataHandler()
                dataHandlerPromise.succeed(dataHandler)

                if self.security != .none {
                    do {
                        let handler = try self.makeTLSHandler()
                        let handshakePromise = channel.eventLoop.makePromise(of: Void.self)
                        handshakeFutureBox.withLockedValue { $0 = handshakePromise.futureResult }
                        try channel.pipeline.syncOperations.addHandler(handler)
                        try channel.pipeline.syncOperations.addHandler(TLSHandshakeCompletionHandler(promise: handshakePromise))
                        try channel.pipeline.syncOperations.addHandler(dataHandler)
                        return channel.eventLoop.makeSucceededVoidFuture()
                    } catch {
                        dataHandlerPromise.fail(error)
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                return channel.pipeline.addHandler(dataHandler)
            }

        let dataChannel = try await waitForFuture(
            bootstrap.connect(host: dataHost, port: dataPort)
        )
        let dataHandler = try await waitForFuture(dataHandlerPromise.futureResult)
        // `connect` only completes after the initializer has run, so the box is settled here.
        return FTPDataConnection(
            channel: dataChannel,
            handler: dataHandler,
            handshake: handshakeFutureBox.withLockedValue { $0 }
        )
    }

    /// Where to open the data connection. `EPSV` (RFC 2428) first: it works over IPv6 and
    /// carries only a port, so a NAT in front of the server cannot get the address wrong.
    /// `PASV` for servers without it.
    private func passiveDataEndpoint() async throws -> (host: String, port: Int) {
        if !epsvRefused.withLockedValue({ $0 }) {
            let response = try await sendCommand("EPSV")
            if response.code == 229 {
                guard let controlHost = currentChannel()?.remoteAddress?.ipAddress else {
                    throw FTPError.notConnected
                }
                return (controlHost, try Self.parseEPSV(response.text))
            }
            guard (500..<600).contains(response.code) else {
                throw FTPError.unexpectedResponse(response)
            }
            epsvRefused.withLockedValue { $0 = true }
        }

        let response = try await sendCommand("PASV")
        guard response.code == 227 else {
            throw FTPError.unexpectedResponse(response)
        }
        let (pasvHost, port) = try Self.parsePASV(response.text)
        return (normalizedDataConnectionHost(pasvHost), port)
    }

    private func waitForFuture<T: Sendable>(_ future: EventLoopFuture<T>) async throws -> T {
        let timeoutPromise = future.eventLoop.makePromise(of: T.self)
        // Both the scheduled task and the completion callback run on `future.eventLoop`,
        // so the flag is only ever touched from that one loop.
        let didTimeOut = NIOLockedValueBox(false)
        let timeoutTask = future.eventLoop.scheduleTask(in: Self.operationTimeout) {
            didTimeOut.withLockedValue { $0 = true }
            timeoutPromise.fail(FTPError.connectionTimedOut)
        }

        future.whenComplete { result in
            timeoutTask.cancel()

            switch result {
            case .success(let value):
                if didTimeOut.withLockedValue({ $0 }) {
                    if let channel = value as? Channel {
                        channel.close(promise: nil)
                    }
                    return
                }
                timeoutPromise.succeed(value)
            case .failure(let error):
                guard !didTimeOut.withLockedValue({ $0 }) else { return }
                timeoutPromise.fail(error)
            }
        }

        return try await timeoutPromise.futureResult.get()
    }

    // MARK: - Passive Reply Parsers

    /// `229 Entering Extended Passive Mode (|||6446|)` → 6446. The delimiter is whatever
    /// character the server repeats; `|` is only the usual one.
    static func parseEPSV(_ text: String) throws -> Int {
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else {
            throw FTPError.protocolError("Cannot parse EPSV response: \(text)")
        }
        let inner = Array(text[text.index(after: open)..<close])
        guard inner.count >= 5, let delimiter = inner.first,
              inner[1] == delimiter, inner[2] == delimiter, inner.last == delimiter,
              let port = Int(String(inner[3..<(inner.count - 1)])), (1...65535).contains(port) else {
            throw FTPError.protocolError("Cannot parse EPSV response: \(text)")
        }
        return port
    }

    static func parsePASV(_ text: String) throws -> (String, Int) {
        // Format: "227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)"
        guard let start = text.firstIndex(of: "("),
              let end = text[text.index(after: start)...].firstIndex(of: ")") else {
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
            UInt8(value & 0xff)
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

    private func replaceChannel(_ channel: Channel?) -> Channel? {
        channelLock.lock()
        let previousChannel = self.channel
        self.channel = channel
        channelLock.unlock()
        return previousChannel
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
final class FTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
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
    // The channel rather than the handler context: `Channel` is `Sendable` and its
    // `close` is safe to call from the timeout callback's arbitrary thread.
    private var channel: Channel?

    func handlerAdded(context: ChannelHandlerContext) {
        lock.lock()
        self.channel = context.channel
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
        let channel: Channel?

        lock.lock()
        if let index = self.continuations.firstIndex(where: { $0.id == id }) {
            terminalError = error
            pendingResponses.removeAll()
            var pending = self.continuations
            let timedOut = pending.remove(at: index)
            continuations = [timedOut.continuation] + pending.map(\.continuation)
            channel = self.channel
            self.continuations.removeAll()
        } else {
            continuations = []
            channel = nil
        }
        lock.unlock()

        continuations.forEach { $0.resume(throwing: error) }
        channel?.close(promise: nil)
    }
}

// MARK: - Data Handler

/// Collects data from an FTP data connection.
final class FTPDataHandler: ChannelInboundHandler, @unchecked Sendable {
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
    private var channel: Channel?
    private var lastActivity = DispatchTime.now()

    func handlerAdded(context: ChannelHandlerContext) {
        lock.lock()
        self.channel = context.channel
        lock.unlock()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        if let bytes = buf.readBytes(length: buf.readableBytes) {
            lock.lock()
            buffer.append(contentsOf: bytes)
            lastActivity = .now()
            lock.unlock()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let result: Result<Data, Error>
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

        continuations.forEach { $0.resume(with: result) }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Servers commonly close a protected data connection without a TLS close_notify.
        // The end of the data is still the end of the stream, and the control connection's
        // completion reply says whether the transfer succeeded.
        if case NIOSSLError.uncleanShutdown = error { return }

        let continuations: [CheckedContinuation<Data, Error>]

        lock.lock()
        terminalError = error
        completed = true
        continuations = self.continuations.map(\.continuation)
        self.continuations.removeAll()
        lock.unlock()

        continuations.forEach { $0.resume(throwing: error) }
    }

    /// Waits for the server to close the connection and returns everything it sent.
    /// `timeout` bounds the time without incoming data, not the whole transfer, so a large
    /// file over a slow link is not cut off.
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
        let interval = DispatchTimeInterval.nanoseconds(Int(max(timeout.nanoseconds, 0)))
        lock.lock()
        let deadline = lastActivity + interval
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: deadline) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let idleSince = self.lastActivity
            let isPending = self.continuations.contains { $0.id == waiterID }
            self.lock.unlock()
            guard isPending else { return }
            if idleSince + interval > .now() {
                self.scheduleTimeout(for: waiterID, timeout: timeout)
            } else {
                self.failContinuationIfPending(id: waiterID, error: FTPError.connectionTimedOut)
            }
        }
    }

    private func failContinuationIfPending(id: UUID, error: Error) {
        let continuationsToResume: [CheckedContinuation<Data, Error>]
        let channel: Channel?

        lock.lock()
        if let index = self.continuations.firstIndex(where: { $0.id == id }) {
            terminalError = error
            completed = true
            var pending = self.continuations
            let timedOut = pending.remove(at: index)
            continuationsToResume = [timedOut.continuation] + pending.map(\.continuation)
            channel = self.channel
            self.continuations.removeAll()
        } else {
            continuationsToResume = []
            channel = nil
        }
        lock.unlock()

        continuationsToResume.forEach { $0.resume(throwing: error) }
        channel?.close(promise: nil)
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
    case controlConnectionLost(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to FTP server"
        case .connectionTimedOut: return "FTP connection timed out"
        case .connectionFailed(let msg): return "FTP connection failed: \(msg)"
        case .authenticationFailed: return "FTP authentication failed"
        case .unexpectedResponse(let response): return "Unexpected FTP response \(response.code): \(response.text)"
        case .protocolError(let msg): return "FTP protocol error: \(msg)"
        case .transferFailed(let msg): return "FTP transfer failed: \(msg)"
        case .controlConnectionLost(let msg): return "FTP control connection is out of sync: \(msg)"
        }
    }
}
