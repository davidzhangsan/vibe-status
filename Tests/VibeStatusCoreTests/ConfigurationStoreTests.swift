import Foundation
import XCTest
@testable import VibeStatusCore

final class ConfigurationStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ConfigurationStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMissingConfigurationUsesEmptyFirstRunDefaults() throws {
        let store = UserDefaultsConfigurationStore(userDefaults: defaults)

        let configuration = try store.load()

        XCTAssertTrue(configuration.hosts.isEmpty)
        XCTAssertFalse(configuration.preferences.launchAtLogin)
    }

    func testRoundTripsVersionedConfiguration() throws {
        let store = UserDefaultsConfigurationStore(userDefaults: defaults)
        let profile = HostProfile(
            id: UUID(uuidString: "9F0A3309-E4D1-437B-B533-BA92C38F0689")!,
            alias: "research-cpu",
            displayName: "Research",
            codexPath: "/opt/codex/bin/codex",
            isEnabled: false
        )
        let configuration = VibeStatusConfiguration(
            hosts: [profile],
            preferences: VibeStatusPreferences(launchAtLogin: true)
        )

        try store.save(configuration)

        XCTAssertEqual(try store.load(), configuration)
        let encoded = try XCTUnwrap(
            defaults.data(forKey: UserDefaultsConfigurationStore.defaultKey)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(
            object["schemaVersion"] as? Int,
            UserDefaultsConfigurationStore.currentSchemaVersion
        )
    }

    func testRejectsUnsupportedSchemaVersion() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "configuration": [:],
        ])
        defaults.set(data, forKey: UserDefaultsConfigurationStore.defaultKey)
        let store = UserDefaultsConfigurationStore(userDefaults: defaults)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(
                error as? ConfigurationStoreError,
                .unsupportedSchemaVersion(99)
            )
        }
    }

    func testResetRemovesPersistedConfiguration() throws {
        let store = UserDefaultsConfigurationStore(userDefaults: defaults)
        try store.save(VibeStatusConfiguration(hosts: []))

        store.reset()

        XCTAssertEqual(try store.load(), .empty)
    }
}
