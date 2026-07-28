import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

public enum WebSocketTextTransportError: Error, Sendable, LocalizedError {
    case alreadyConnected
    case disconnected
    case descriptorDuplicationFailed(Int32)
    case sshExited(alias: String, status: Int32, diagnostics: String)
    case handshakeTimedOut
    case unexpectedHTTPResponse(Int)
    case binaryMessage
    case invalidFragmentSequence
    case invalidUTF8
    case messageTooLarge

    public var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            "The transport is already connected."
        case .disconnected:
            "The remote Codex connection closed."
        case let .descriptorDuplicationFailed(code):
            "Could not duplicate an SSH pipe descriptor (errno \(code))."
        case let .sshExited(alias, status, diagnostics):
            Self.sshExitDescription(
                alias: alias,
                status: status,
                diagnostics: diagnostics
            )
        case .handshakeTimedOut:
            "The Codex WebSocket upgrade timed out."
        case let .unexpectedHTTPResponse(status):
            "The Codex proxy rejected the WebSocket upgrade (HTTP \(status))."
        case .binaryMessage:
            "The Codex proxy sent an unsupported binary WebSocket message."
        case .invalidFragmentSequence:
            "The Codex proxy sent an invalid fragmented WebSocket message."
        case .invalidUTF8:
            "The Codex proxy sent a text frame that was not valid UTF-8."
        case .messageTooLarge:
            "The Codex proxy sent a WebSocket message larger than 16 MiB."
        }
    }

    private static func sshExitDescription(
        alias: String,
        status: Int32,
        diagnostics: String
    ) -> String {
        let detail = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
        let guidance = status == 255
            ? " Run “ssh \(alias)” once in Terminal, then retry."
            : ""
        let suffix = detail.isEmpty ? "" : " \(detail)"
        return "The SSH connection exited with status \(status).\(guidance)\(suffix)"
    }
}

/// A WebSocket-over-stdio transport backed by one owned SSH process.
///
/// SwiftNIO owns duplicated descriptors for the SSH child's stdout/stdin
/// pipes. Foundation retains the originals so process teardown and stderr
/// diagnostics stay independent from the protocol stream.
public actor NIOWebSocketTextTransport: CodexTextTransport {
    public static let maximumMessageBytes = 16 * 1_024 * 1_024

    private let profile: HostProfile
    private let handshakeTimeout: Duration
    private let diagnostics: BoundedDiagnosticRing

    private var sshTransport: SSHProcessTransport?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var channel: Channel?
    private var inbox: TextMessageInbox?

    public init(
        profile: HostProfile,
        handshakeTimeout: Duration = .seconds(10),
        diagnostics: BoundedDiagnosticRing = .init()
    ) {
        self.profile = profile
        self.handshakeTimeout = handshakeTimeout
        self.diagnostics = diagnostics
    }

    public func connect() async throws {
        guard sshTransport == nil, channel == nil else {
            throw WebSocketTextTransportError.alreadyConnected
        }

        let inbox = TextMessageInbox()
        let upgrade = UpgradeLatch()
        let profile = self.profile
        let diagnostics = self.diagnostics
        let sshTransport = try SSHProcessTransport(
            profile: profile,
            diagnostics: diagnostics,
            onTermination: { termination in
                let error = WebSocketTextTransportError.sshExited(
                    alias: profile.alias,
                    status: termination.status,
                    diagnostics: diagnostics.snapshotText()
                )
                upgrade.fail(error)
                inbox.finish(throwing: error)
            }
        )
        try sshTransport.start()
        let descriptors = try sshTransport.duplicatePipeDescriptors()
        let requestHandler = WebSocketUpgradeRequestHandler(upgrade: upgrade)
        let websocketHandler = WebSocketTextFrameHandler(
            inbox: inbox,
            upgrade: upgrade,
            maximumMessageBytes: Self.maximumMessageBytes
        )
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            let bootstrap = NIOPipeBootstrap(group: group)
                .channelInitializer { channel in
                    let upgrader = NIOWebSocketClientUpgrader(
                        maxFrameSize: Self.maximumMessageBytes,
                        upgradePipelineHandler: { channel, _ in
                            channel.pipeline.addHandler(websocketHandler).map {
                                upgrade.succeed()
                            }
                        }
                    )
                    let configuration: NIOHTTPClientUpgradeSendableConfiguration = (
                        upgraders: [upgrader],
                        completionHandler: { context in
                            context.pipeline.removeHandler(
                                requestHandler,
                                promise: nil
                            )
                        }
                    )
                    return channel.pipeline
                        .addHTTPClientHandlers(withClientUpgrade: configuration)
                        .flatMap {
                            channel.pipeline.addHandler(requestHandler)
                        }
                }

            let channel = try await bootstrap
                .takingOwnershipOfDescriptors(
                    input: descriptors.readDescriptor,
                    output: descriptors.writeDescriptor
                )
                .get()

            self.sshTransport = sshTransport
            self.eventLoopGroup = group
            self.channel = channel
            self.inbox = inbox

            try await waitForUpgrade(upgrade)
        } catch {
            inbox.finish(throwing: error)
            if self.channel == nil {
                Darwin.close(descriptors.readDescriptor)
                Darwin.close(descriptors.writeDescriptor)
            }
            sshTransport.stop()
            try? await group.shutdownGracefully()
            clearLocalState()
            throw error
        }
    }

    public func send(_ text: String) async throws {
        guard let channel, channel.isActive else {
            throw WebSocketTextTransportError.disconnected
        }
        let utf8 = Array(text.utf8)
        guard utf8.count <= Self.maximumMessageBytes else {
            throw WebSocketTextTransportError.messageTooLarge
        }
        var buffer = channel.allocator.buffer(capacity: utf8.count)
        buffer.writeBytes(utf8)
        let frame = WebSocketFrame(
            fin: true,
            opcode: .text,
            maskKey: .random(),
            data: buffer
        )
        try await channel.writeAndFlush(frame).get()
    }

    public func receive() async throws -> String? {
        guard let inbox else {
            throw WebSocketTextTransportError.disconnected
        }
        return try await inbox.next()
    }

    public func close() async {
        if let channel {
            let buffer = channel.allocator.buffer(capacity: 0)
            let closeFrame = WebSocketFrame(
                fin: true,
                opcode: .connectionClose,
                maskKey: .random(),
                data: buffer
            )
            _ = try? await channel.writeAndFlush(closeFrame).get()
            _ = try? await channel.close().get()
        }

        sshTransport?.stop()
        if let eventLoopGroup {
            try? await eventLoopGroup.shutdownGracefully()
        }
        clearLocalState()
    }

    public func diagnosticText() -> String {
        diagnostics.snapshotText()
    }

    private func waitForUpgrade(_ upgrade: UpgradeLatch) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await upgrade.wait()
            }
            group.addTask { [handshakeTimeout] in
                try await Task.sleep(for: handshakeTimeout)
                throw WebSocketTextTransportError.handshakeTimedOut
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func clearLocalState() {
        sshTransport = nil
        channel = nil
        eventLoopGroup = nil
        inbox = nil
    }
}

private final class WebSocketUpgradeRequestHandler:
    ChannelInboundHandler,
    RemovableChannelHandler,
    @unchecked Sendable
{
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let upgrade: UpgradeLatch

    init(upgrade: UpgradeLatch) {
        self.upgrade = upgrade
    }

    func channelActive(context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "localhost")
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPRequestHead(
            version: .http1_1,
            method: .GET,
            uri: "/",
            headers: headers
        )
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(
            wrapOutboundOut(.body(.byteBuffer(
                context.channel.allocator.buffer(capacity: 0)
            ))),
            promise: nil
        )
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        if case let .head(head) = part, head.status != .switchingProtocols {
            let error = WebSocketTextTransportError.unexpectedHTTPResponse(
                Int(head.status.code)
            )
            upgrade.fail(error)
            context.fireErrorCaught(error)
            context.close(promise: nil)
            return
        }
        context.fireChannelRead(data)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        upgrade.fail(error)
        context.close(promise: nil)
    }
}

final class WebSocketTextFrameHandler:
    ChannelInboundHandler,
    @unchecked Sendable
{
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let inbox: TextMessageInbox
    private let upgrade: UpgradeLatch
    private let maximumMessageBytes: Int
    private var fragments: [UInt8]?

    init(
        inbox: TextMessageInbox,
        upgrade: UpgradeLatch,
        maximumMessageBytes: Int
    ) {
        self.inbox = inbox
        self.upgrade = upgrade
        self.maximumMessageBytes = maximumMessageBytes
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var frame = unwrapInboundIn(data)
        guard frame.maskKey == nil else {
            fail(WebSocketTextTransportError.invalidFragmentSequence, context)
            return
        }
        switch frame.opcode {
        case .text:
            guard fragments == nil else {
                fail(WebSocketTextTransportError.invalidFragmentSequence, context)
                return
            }
            guard let bytes = bytes(from: &frame) else {
                fail(WebSocketTextTransportError.messageTooLarge, context)
                return
            }
            if frame.fin {
                emit(bytes, context)
            } else {
                fragments = bytes
            }
        case .continuation:
            guard var accumulated = fragments,
                  let bytes = bytes(from: &frame),
                  accumulated.count + bytes.count <= maximumMessageBytes
            else {
                fail(WebSocketTextTransportError.invalidFragmentSequence, context)
                return
            }
            accumulated.append(contentsOf: bytes)
            if frame.fin {
                fragments = nil
                emit(accumulated, context)
            } else {
                fragments = accumulated
            }
        case .ping:
            let payload = frame.unmaskedData
            let pong = WebSocketFrame(
                fin: true,
                opcode: .pong,
                maskKey: .random(),
                data: payload
            )
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .pong:
            break
        case .connectionClose:
            let payload = frame.unmaskedData
            let close = WebSocketFrame(
                fin: true,
                opcode: .connectionClose,
                maskKey: .random(),
                data: payload
            )
            context.writeAndFlush(wrapOutboundOut(close), promise: nil)
            context.close(promise: nil)
        case .binary:
            fail(WebSocketTextTransportError.binaryMessage, context)
        default:
            fail(WebSocketTextTransportError.invalidFragmentSequence, context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        inbox.finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, context)
    }

    private func bytes(from frame: inout WebSocketFrame) -> [UInt8]? {
        var buffer = frame.unmaskedData
        guard buffer.readableBytes <= maximumMessageBytes else { return nil }
        return buffer.readBytes(length: buffer.readableBytes)
    }

    private func emit(_ bytes: [UInt8], _ context: ChannelHandlerContext) {
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            fail(WebSocketTextTransportError.invalidUTF8, context)
            return
        }
        inbox.yield(text)
    }

    private func fail(_ error: Error, _ context: ChannelHandlerContext) {
        upgrade.fail(error)
        inbox.finish(throwing: error)
        context.fireErrorCaught(error)
        context.close(promise: nil)
    }
}

final class TextMessageInbox: @unchecked Sendable {
    private enum Terminal {
        case open
        case finished
        case failed(Error)
    }

    private let lock = NSLock()
    private var messages: [String] = []
    private var waiter: CheckedContinuation<String?, Error>?
    private var terminal: Terminal = .open

    func next() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<String?, Error>? = lock.withLock {
                if !messages.isEmpty {
                    return .success(messages.removeFirst())
                }
                switch terminal {
                case .open:
                    precondition(waiter == nil, "Only one inbox consumer is supported")
                    waiter = continuation
                    return nil
                case .finished:
                    return .success(nil)
                case let .failed(error):
                    return .failure(error)
                }
            }
            if let immediate {
                continuation.resume(with: immediate)
            }
        }
    }

    func yield(_ text: String) {
        let waiter: CheckedContinuation<String?, Error>? = lock.withLock {
            guard case .open = terminal else { return nil }
            if let waiter = self.waiter {
                self.waiter = nil
                return waiter
            }
            messages.append(text)
            if messages.count > 256 {
                messages.removeFirst(messages.count - 256)
            }
            return nil
        }
        waiter?.resume(returning: text)
    }

    func finish(throwing error: Error? = nil) {
        let waiter: CheckedContinuation<String?, Error>? = lock.withLock {
            guard case .open = terminal else { return nil }
            terminal = error.map(Terminal.failed) ?? .finished
            let waiter = self.waiter
            self.waiter = nil
            return waiter
        }
        if let error {
            waiter?.resume(throwing: error)
        } else {
            waiter?.resume(returning: nil)
        }
    }
}

final class UpgradeLatch: @unchecked Sendable {
    private enum State {
        case pending([CheckedContinuation<Void, Error>])
        case resolved(Result<Void, Error>)
    }

    private let lock = NSLock()
    private var state: State = .pending([])

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result: Result<Void, Error>? = lock.withLock {
                switch state {
                case var .pending(waiters):
                    waiters.append(continuation)
                    state = .pending(waiters)
                    return nil
                case let .resolved(result):
                    return result
                }
            }
            if let result {
                continuation.resume(with: result)
            }
        }
    }

    func succeed() {
        resolve(.success(()))
    }

    func fail(_ error: Error) {
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<Void, Error>) {
        let waiters: [CheckedContinuation<Void, Error>] = lock.withLock {
            guard case let .pending(waiters) = state else { return [] }
            state = .resolved(result)
            return waiters
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }
}
