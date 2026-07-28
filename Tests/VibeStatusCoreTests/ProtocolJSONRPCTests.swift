import Foundation
import XCTest
@testable import VibeStatusCore

final class ProtocolJSONRPCTests: XCTestCase {
    func testDecodesResponseWithoutJSONRPCVersion() throws {
        let message = try JSONRPCCodec().decode(
            #"{"id":7,"result":{"futureField":{"nested":true}}}"#
        )

        guard case let .response(id, result, error) = message else {
            return XCTFail("Expected a response")
        }
        XCTAssertEqual(id, .integer(7))
        XCTAssertNil(error)
        XCTAssertEqual(result?["futureField"]?["nested"]?.boolValue, true)
    }

    func testDecodesVersionedNotificationAndPreservesParams() throws {
        let message = try JSONRPCCodec().decode(
            #"{"jsonrpc":"2.0","method":"future/event","params":{"value":42}}"#
        )

        guard case let .notification(notification) = message else {
            return XCTFail("Expected a notification")
        }
        XCTAssertEqual(notification.method, "future/event")
        XCTAssertEqual(notification.params?["value"]?.doubleValue, 42)
    }

    func testEncodedRequestOmitsJSONRPCVersion() throws {
        let text = try JSONRPCCodec().encodeRequest(
            id: .integer(1),
            method: "thread/loaded/list",
            params: .object([:])
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any]
        )

        XCTAssertNil(object["jsonrpc"])
        XCTAssertEqual(object["method"] as? String, "thread/loaded/list")
        XCTAssertNotNil(object["params"] as? [String: Any])
    }

    func testRejectsIncomingRequestWithMethodNotFoundShape() throws {
        let message = try JSONRPCCodec().decode(
            #"{"id":"approval-1","method":"item/commandExecution/requestApproval","params":{}}"#
        )
        guard case let .request(id, method, _) = message else {
            return XCTFail("Expected a request")
        }
        XCTAssertEqual(id, .string("approval-1"))
        XCTAssertEqual(method, "item/commandExecution/requestApproval")

        let response = try JSONRPCCodec().encodeErrorResponse(
            id: id,
            error: .init(code: -32601, message: "Method not supported by observer")
        )
        XCTAssertTrue(response.contains(#""code":-32601"#))
    }
}
