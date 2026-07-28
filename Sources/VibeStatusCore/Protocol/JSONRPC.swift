import Foundation

public enum JSONRPCID: Sendable, Hashable, Codable {
    case integer(Int64)
    case string(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .integer(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        }
    }
}

public struct JSONRPCErrorObject: Error, Sendable, Hashable, Codable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct JSONRPCNotification: Sendable, Hashable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

public enum JSONRPCIncomingMessage: Sendable, Hashable {
    case response(id: JSONRPCID, result: JSONValue?, error: JSONRPCErrorObject?)
    case request(id: JSONRPCID, method: String, params: JSONValue?)
    case notification(JSONRPCNotification)
}

public enum JSONRPCCodecError: Error, Sendable, Equatable {
    case invalidUTF8
    case nonObjectMessage
    case missingMessageDiscriminator
    case invalidID
}

/// Codec for the app-server's JSON-RPC-like wire format. Codex currently omits
/// the conventional `jsonrpc: "2.0"` member; decoding tolerates either form and
/// encoding intentionally omits it.
public struct JSONRPCCodec: Sendable {
    public init() {}

    public func decode(_ text: String) throws -> JSONRPCIncomingMessage {
        guard let data = text.data(using: .utf8) else {
            throw JSONRPCCodecError.invalidUTF8
        }
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case let .object(object) = value else {
            throw JSONRPCCodecError.nonObjectMessage
        }

        let id = try object["id"].map(decodeID)
        let method = object["method"]?.stringValue
        let params = object["params"]

        if let method {
            if let id {
                return .request(id: id, method: method, params: params)
            }
            return .notification(.init(method: method, params: params))
        }

        if let id, object["result"] != nil || object["error"] != nil {
            let error = try object["error"].flatMap { value -> JSONRPCErrorObject? in
                if case .null = value { return nil }
                return try value.decode(JSONRPCErrorObject.self)
            }
            return .response(id: id, result: object["result"], error: error)
        }

        throw JSONRPCCodecError.missingMessageDiscriminator
    }

    public func encodeRequest(
        id: JSONRPCID,
        method: String,
        params: JSONValue? = nil
    ) throws -> String {
        var object: [String: JSONValue] = [
            "id": encodeID(id),
            "method": .string(method),
        ]
        if let params {
            object["params"] = params
        }
        return try encodeObject(object)
    }

    public func encodeNotification(
        method: String,
        params: JSONValue? = nil
    ) throws -> String {
        var object: [String: JSONValue] = ["method": .string(method)]
        if let params {
            object["params"] = params
        }
        return try encodeObject(object)
    }

    public func encodeErrorResponse(
        id: JSONRPCID,
        error: JSONRPCErrorObject
    ) throws -> String {
        try encodeObject([
            "id": encodeID(id),
            "error": try JSONValue.encode(error),
        ])
    }

    private func encodeObject(_ object: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONValue.object(object))
        guard let text = String(data: data, encoding: .utf8) else {
            throw JSONRPCCodecError.invalidUTF8
        }
        return text
    }

    private func decodeID(_ value: JSONValue) throws -> JSONRPCID {
        switch value {
        case let .string(id):
            return .string(id)
        case let .number(id) where id.rounded() == id:
            return .integer(Int64(id))
        default:
            throw JSONRPCCodecError.invalidID
        }
    }

    private func encodeID(_ id: JSONRPCID) -> JSONValue {
        switch id {
        case let .integer(value):
            return .number(Double(value))
        case let .string(value):
            return .string(value)
        }
    }
}
