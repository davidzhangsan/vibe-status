import NIOCore
import NIOEmbedded
import NIOWebSocket
import XCTest
@testable import VibeStatusCore

final class TransportWebSocketTests: XCTestCase {
    func testYieldsCompleteTextFrame() async throws {
        let fixture = try makeFixture()
        var payload = fixture.channel.allocator.buffer(capacity: 5)
        payload.writeString("hello")

        XCTAssertNoThrow(
            try fixture.channel.writeInbound(
                WebSocketFrame(fin: true, opcode: .text, data: payload)
            )
        )
        let message = try await fixture.inbox.next()
        XCTAssertEqual(message, "hello")
        XCTAssertNoThrow(try fixture.channel.finish())
    }

    func testReassemblesFragmentedTextFrames() async throws {
        let fixture = try makeFixture()
        var first = fixture.channel.allocator.buffer(capacity: 3)
        first.writeString("hel")
        var second = fixture.channel.allocator.buffer(capacity: 2)
        second.writeString("lo")

        XCTAssertNoThrow(
            try fixture.channel.writeInbound(
                WebSocketFrame(fin: false, opcode: .text, data: first)
            )
        )
        XCTAssertNoThrow(
            try fixture.channel.writeInbound(
                WebSocketFrame(fin: true, opcode: .continuation, data: second)
            )
        )
        let message = try await fixture.inbox.next()
        XCTAssertEqual(message, "hello")
        XCTAssertNoThrow(try fixture.channel.finish())
    }

    func testPingProducesMaskedPong() throws {
        let fixture = try makeFixture()
        var payload = fixture.channel.allocator.buffer(capacity: 4)
        payload.writeString("ping")

        XCTAssertNoThrow(
            try fixture.channel.writeInbound(
                WebSocketFrame(fin: true, opcode: .ping, data: payload)
            )
        )
        let pong = try XCTUnwrap(
            fixture.channel.readOutbound(as: WebSocketFrame.self)
        )
        XCTAssertEqual(pong.opcode, .pong)
        XCTAssertNotNil(pong.maskKey)
        XCTAssertEqual(
            String(buffer: pong.data),
            "ping"
        )
        XCTAssertNoThrow(try fixture.channel.finish())
    }

    func testRejectsInvalidUTF8() async throws {
        let fixture = try makeFixture()
        var payload = fixture.channel.allocator.buffer(capacity: 1)
        payload.writeInteger(UInt8(0xFF))

        XCTAssertThrowsError(
            try fixture.channel.writeInbound(
                WebSocketFrame(fin: true, opcode: .text, data: payload)
            )
        )
        do {
            _ = try await fixture.inbox.next()
            XCTFail("Expected invalid UTF-8 to fail the inbox")
        } catch let error as WebSocketTextTransportError {
            guard case .invalidUTF8 = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        _ = try? fixture.channel.finish()
    }

    func testRejectsMessageOverConfiguredLimit() async throws {
        let fixture = try makeFixture(maximumMessageBytes: 4)
        var payload = fixture.channel.allocator.buffer(capacity: 5)
        payload.writeString("12345")

        XCTAssertThrowsError(
            try fixture.channel.writeInbound(
                WebSocketFrame(fin: true, opcode: .text, data: payload)
            )
        )
        do {
            _ = try await fixture.inbox.next()
            XCTFail("Expected oversized frame to fail the inbox")
        } catch let error as WebSocketTextTransportError {
            guard case .messageTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        _ = try? fixture.channel.finish()
    }

    func testRejectsMaskedServerFrame() async throws {
        let fixture = try makeFixture()
        var payload = fixture.channel.allocator.buffer(capacity: 4)
        payload.writeString("nope")

        XCTAssertThrowsError(
            try fixture.channel.writeInbound(
                WebSocketFrame(
                    fin: true,
                    opcode: .text,
                    maskKey: [1, 2, 3, 4],
                    data: payload
                )
            )
        )
        do {
            _ = try await fixture.inbox.next()
            XCTFail("Expected masked server frame to fail the inbox")
        } catch let error as WebSocketTextTransportError {
            guard case .invalidFragmentSequence = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        _ = try? fixture.channel.finish()
    }

    private func makeFixture(
        maximumMessageBytes: Int = 1_024
    ) throws -> (
        channel: EmbeddedChannel,
        inbox: TextMessageInbox
    ) {
        let inbox = TextMessageInbox()
        let latch = UpgradeLatch()
        let handler = WebSocketTextFrameHandler(
            inbox: inbox,
            upgrade: latch,
            maximumMessageBytes: maximumMessageBytes
        )
        return (EmbeddedChannel(handler: handler), inbox)
    }
}
