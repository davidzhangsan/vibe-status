import Foundation

public enum ConfigurationStoreError: Error, Equatable, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case corruptData

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "Configuration schema version \(version) is not supported."
        case .corruptData:
            return "The saved Vibe Status configuration could not be decoded."
        }
    }
}

/// Stores only host aliases, labels, executable paths, and local preferences.
///
/// Runtime task state and remote credentials deliberately have no representation
/// in this store.
public final class UserDefaultsConfigurationStore: @unchecked Sendable {
    public static let currentSchemaVersion = 1
    public static let defaultKey = "com.jamescai.VibeStatus.configuration"

    private struct Header: Decodable {
        let schemaVersion: Int
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let configuration: VibeStatusConfiguration
    }

    private let userDefaults: UserDefaults
    private let key: String
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        userDefaults: UserDefaults = .standard,
        key: String = UserDefaultsConfigurationStore.defaultKey
    ) {
        self.userDefaults = userDefaults
        self.key = key

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func load(
        default defaultConfiguration: VibeStatusConfiguration = .empty
    ) throws -> VibeStatusConfiguration {
        try lock.withLock {
            guard let data = userDefaults.data(forKey: key) else {
                return defaultConfiguration
            }

            guard let header = try? decoder.decode(Header.self, from: data) else {
                throw ConfigurationStoreError.corruptData
            }
            guard header.schemaVersion == Self.currentSchemaVersion else {
                throw ConfigurationStoreError.unsupportedSchemaVersion(header.schemaVersion)
            }
            guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
                throw ConfigurationStoreError.corruptData
            }
            return envelope.configuration
        }
    }

    public func save(_ configuration: VibeStatusConfiguration) throws {
        try lock.withLock {
            let envelope = Envelope(
                schemaVersion: Self.currentSchemaVersion,
                configuration: configuration
            )
            let data = try encoder.encode(envelope)
            userDefaults.set(data, forKey: key)
        }
    }

    public func reset() {
        lock.withLock {
            userDefaults.removeObject(forKey: key)
        }
    }
}
