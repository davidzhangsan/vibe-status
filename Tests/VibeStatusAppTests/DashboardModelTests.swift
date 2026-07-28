import Foundation
import XCTest
import VibeStatusCore
@testable import VibeStatus

@MainActor
final class DashboardModelTests: XCTestCase {
    func testSnapshotDrivesAllThreeMenuBarCounts() async {
        let defaults = makeDefaults(onboardingComplete: true)
        let client = TestDashboardClient()
        let model = DashboardModel(client: client, defaults: defaults)

        model.start()
        await Task.yield()
        await client.publish(
            DashboardSnapshot(
                sessions: [
                    session("needs-attention", status: .needsAttention),
                    session("working", status: .working),
                    session("ready-1", status: .ready),
                    session("ready-2", status: .ready),
                ]
            )
        )

        await waitUntil { model.menuBarCounts.ready == 2 }

        XCTAssertEqual(
            model.menuBarCounts,
            StatusCounts(needsAttention: 1, working: 1, ready: 2)
        )
        await model.stop()
    }

    func testCleanInstallStartsWithNoSelectedHosts() {
        let defaults = makeDefaults()
        let model = DashboardModel(
            client: TestDashboardClient(),
            defaults: defaults
        )

        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertEqual(model.destination, .onboarding)
    }

    func testCompletionFlagWithoutConfigurationReturnsToOnboarding() {
        let defaults = makeDefaults(
            onboardingComplete: true,
            includeConfiguration: false
        )
        let model = DashboardModel(
            client: TestDashboardClient(),
            defaults: defaults
        )

        XCTAssertTrue(model.hosts.isEmpty)
        XCTAssertEqual(model.destination, .onboarding)
    }

    func testAutoDetectedCodexPathIsSavedWhenOnboardingCompletes() async throws {
        let defaults = makeDefaults()
        let model = DashboardModel(
            client: TestDashboardClient(),
            defaults: defaults
        )
        model.addHost(alias: "research-host")
        let host = try XCTUnwrap(model.hosts.first)

        model.validate(host: host)
        await waitUntil {
            model.validationStates[host.id]?.isValid == true
        }
        model.completeOnboarding()

        let saved = try UserDefaultsConfigurationStore(
            userDefaults: defaults
        ).load()
        XCTAssertEqual(saved.hosts.first?.alias, "research-host")
        XCTAssertEqual(saved.hosts.first?.codexPath, "/usr/local/bin/codex")
        XCTAssertEqual(model.destination, .dashboard)
        await model.stop()
    }

    func testSessionsUseCoreStatusGroupingAndRecencyOrder() async {
        let defaults = makeDefaults(onboardingComplete: true)
        let client = TestDashboardClient()
        let model = DashboardModel(client: client, defaults: defaults)
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)

        model.start()
        await Task.yield()
        await client.publish(
            DashboardSnapshot(
                sessions: [
                    SessionSnapshot(
                        hostID: "compute-a",
                        threadID: "older",
                        name: "Older",
                        updatedAt: older,
                        status: .working
                    ),
                    SessionSnapshot(
                        hostID: "build-host",
                        threadID: "newer",
                        name: "Newer",
                        updatedAt: newer,
                        status: .working
                    ),
                ]
            )
        )

        await waitUntil { model.sessions.count == 2 }

        XCTAssertEqual(
            model.sessions(for: .working).map(\.threadID),
            ["newer", "older"]
        )
        await model.stop()
    }

    private func makeDefaults(
        onboardingComplete: Bool = false,
        includeConfiguration: Bool = true
    ) -> UserDefaults {
        let suiteName = "VibeStatusAppTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(onboardingComplete, forKey: "onboardingComplete.v1")
        if onboardingComplete, includeConfiguration {
            try! UserDefaultsConfigurationStore(userDefaults: defaults).save(
                VibeStatusConfiguration(
                    hosts: [
                        HostProfile(
                            alias: "compute-a",
                            codexPath: "/usr/local/bin/codex"
                        ),
                    ]
                )
            )
        }
        return defaults
    }

    private func session(
        _ id: String,
        status: TaskDisplayStatus
    ) -> SessionSnapshot {
        SessionSnapshot(
            hostID: "compute-a",
            threadID: id,
            name: id,
            updatedAt: Date(),
            status: status
        )
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool
    ) async {
        for _ in 0..<50 {
            if condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor TestDashboardClient: DashboardClient {
    private let stream: AsyncStream<DashboardSnapshot>
    private let continuation: AsyncStream<DashboardSnapshot>.Continuation

    init() {
        let pair = AsyncStream<DashboardSnapshot>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
    }

    func snapshots() async -> AsyncStream<DashboardSnapshot> { stream }
    func start(hosts: [HostProfile]) async {}
    func reconfigure(hosts: [HostProfile]) async {}
    func refresh() async {}
    func retry(hostID: String) async {}
    func suspend() async {}
    func resume() async {}
    func stop() async { continuation.finish() }
    func discoverSSHAliases() async -> [String] { [] }

    func validate(host: HostProfile) async -> HostValidationResult {
        HostValidationResult(
            isValid: true,
            version: "codex-cli 0.145.0",
            resolvedCodexPath: host.codexPath.isEmpty
                ? "/usr/local/bin/codex"
                : host.codexPath
        )
    }

    func publish(_ snapshot: DashboardSnapshot) {
        continuation.yield(snapshot)
    }
}
