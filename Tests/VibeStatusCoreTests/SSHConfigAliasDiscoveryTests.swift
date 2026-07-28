import Foundation
import XCTest
@testable import VibeStatusCore

final class SSHConfigAliasDiscoveryTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var sshDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SSHConfigAliasDiscoveryTests-\(UUID().uuidString)")
        sshDirectory = temporaryDirectory.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(
            at: sshDirectory.appendingPathComponent("config.d"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        sshDirectory = nil
        try super.tearDownWithError()
    }

    func testDiscoversLiteralAliasesAcrossIncludesInFirstSeenOrder() throws {
        try write(
            """
            # Defaults and patterns are not destinations.
            Host *
              ServerAliveInterval 15
            Host compute-a build-host !excluded wildcard-*
            Include config.d/*.conf
            Include cycle.conf
            """,
            to: sshDirectory.appendingPathComponent("config")
        )
        try write(
            """
            Host build-host gpu-1
            """,
            to: sshDirectory.appendingPathComponent("config.d/10-hosts.conf")
        )
        try write(
            """
            Host="quoted-host"
            """,
            to: sshDirectory.appendingPathComponent("config.d/20-quoted.conf")
        )
        try write(
            """
            Include config
            Host cycle-host
            """,
            to: sshDirectory.appendingPathComponent("cycle.conf")
        )

        let discovery = SSHConfigAliasDiscovery(homeDirectory: temporaryDirectory)

        XCTAssertEqual(
            try discovery.discover(),
            ["compute-a", "build-host", "gpu-1", "quoted-host", "cycle-host"]
        )
    }

    func testExpandsHomeRelativeIncludeAndIgnoresMissingMatches() throws {
        try write(
            """
            Include ~/.ssh/extra.conf ~/.ssh/missing/*.conf
            Host local
            """,
            to: sshDirectory.appendingPathComponent("config")
        )
        try write(
            "Host included\n",
            to: sshDirectory.appendingPathComponent("extra.conf")
        )

        let discovery = SSHConfigAliasDiscovery(homeDirectory: temporaryDirectory)

        XCTAssertEqual(try discovery.discover(), ["included", "local"])
    }

    func testMissingRootConfigReturnsEmptyList() throws {
        let discovery = SSHConfigAliasDiscovery(homeDirectory: temporaryDirectory)

        XCTAssertEqual(try discovery.discover(), [])
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
