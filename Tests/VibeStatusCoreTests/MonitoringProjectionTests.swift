import Foundation
import XCTest
@testable import VibeStatusCore

final class MonitoringProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_720_000_000)

    func testMapsThreeVisibleStatesAndExcludesNotLoadedAndErrorsFromCounts() {
        let projector = ThreadProjector()
        let snapshot = projector.hostSnapshot(
            hostID: "host-a",
            threads: [
                thread("blue", .active, flags: ["waitingOnApproval"]),
                thread("yellow", .active),
                thread("green", .idle),
                thread("gone", .notLoaded),
                thread("error", .systemError),
            ],
            now: now
        )
        let dashboard = DashboardSnapshot(
            sessions: snapshot.sessions,
            issues: snapshot.issues
        )

        XCTAssertEqual(
            dashboard.counts,
            .init(needsAttention: 1, working: 1, ready: 1)
        )
        XCTAssertEqual(snapshot.issues.count, 1)
        XCTAssertEqual(snapshot.issues.first?.kind, .systemError)
    }

    func testWaitingForUserInputIsNeedsAttention() {
        let snapshot = ThreadProjector().hostSnapshot(
            hostID: "host-b",
            threads: [
                thread("input", .active, flags: ["waitingOnUserInput"]),
            ],
            now: now
        )
        XCTAssertEqual(snapshot.sessions.first?.status, .needsAttention)
    }

    func testFiltersChildrenSessionMismatchAndSubagentSources() {
        let root = thread("root", .idle)
        let child = CodexThread(
            id: "child",
            parentThreadID: "root",
            status: .init(kind: .idle)
        )
        let mismatchedSession = CodexThread(
            id: "child-2",
            sessionID: "root",
            status: .init(kind: .idle)
        )
        let sourceChild = CodexThread(
            id: "child-3",
            status: .init(kind: .idle),
            source: .object(["type": .string("subAgent")])
        )
        let roleChild = CodexThread(
            id: "child-4",
            status: .init(kind: .idle),
            agentRole: "worker"
        )

        let snapshot = ThreadProjector().hostSnapshot(
            hostID: "host-a",
            threads: [root, child, mismatchedSession, sourceChild, roleChild],
            now: now
        )
        XCTAssertEqual(snapshot.sessions.map(\.threadID), ["root"])
    }

    func testFoldsWorkingSideConversationIntoMainThread() {
        let snapshot = ThreadProjector().hostSnapshot(
            hostID: "host-a",
            threads: [
                thread("main", .idle),
                sideThread("side", parentID: "main", kind: .active),
            ],
            now: now
        )

        XCTAssertEqual(snapshot.sessions.map(\.threadID), ["main"])
        XCTAssertEqual(snapshot.sessions.first?.status, .working)
    }

    func testFoldsAlreadyRunningSideConversationUsingSessionTree() {
        let side = CodexThread(
            id: "side",
            name: "side",
            updatedAt: now.addingTimeInterval(1),
            sessionID: "main",
            ephemeral: true,
            status: .init(kind: .active)
        )
        let snapshot = ThreadProjector().hostSnapshot(
            hostID: "host-a",
            threads: [thread("main", .idle), side],
            now: now
        )

        XCTAssertEqual(snapshot.sessions.map(\.threadID), ["main"])
        XCTAssertEqual(snapshot.sessions.first?.status, .working)
    }

    func testFoldsAlreadyRunningSideConversationUsingUniqueCWD() {
        let main = CodexThread(
            id: "main",
            name: "main",
            cwd: "/repo",
            updatedAt: now,
            sessionID: "main",
            status: .init(kind: .idle)
        )
        let side = CodexThread(
            id: "side",
            name: "side",
            cwd: "/repo",
            updatedAt: now.addingTimeInterval(1),
            sessionID: "side",
            ephemeral: true,
            status: .init(kind: .active)
        )
        let snapshot = ThreadProjector().hostSnapshot(
            hostID: "host-a",
            threads: [main, side],
            now: now
        )

        XCTAssertEqual(snapshot.sessions.map(\.threadID), ["main"])
        XCTAssertEqual(snapshot.sessions.first?.status, .working)
    }

    func testDoesNotGuessSideConversationParentWhenCWDIsAmbiguous() {
        let roots = ["main-a", "main-b"].map {
            CodexThread(
                id: $0,
                name: $0,
                cwd: "/repo",
                updatedAt: now,
                sessionID: $0,
                status: .init(kind: .idle)
            )
        }
        let side = CodexThread(
            id: "side",
            cwd: "/repo",
            sessionID: "side",
            ephemeral: true,
            status: .init(kind: .active)
        )
        let snapshot = ThreadProjector().hostSnapshot(
            hostID: "host-a",
            threads: roots + [side],
            now: now
        )

        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertTrue(snapshot.sessions.allSatisfy { $0.status == .ready })
    }

    func testFoldsSideConversationAttentionIntoMainThread() {
        let snapshot = ThreadProjector().hostSnapshot(
            hostID: "host-a",
            threads: [
                thread("main", .idle),
                sideThread(
                    "side",
                    parentID: "main",
                    kind: .active,
                    flags: ["waitingOnUserInput"]
                ),
            ],
            now: now
        )

        XCTAssertEqual(snapshot.sessions.map(\.threadID), ["main"])
        XCTAssertEqual(snapshot.sessions.first?.status, .needsAttention)
    }

    func testFinishedSideConversationDoesNotAddAReadyThread() {
        let snapshot = ThreadProjector().hostSnapshot(
            hostID: "host-a",
            threads: [
                thread("main", .idle),
                sideThread("side", parentID: "main", kind: .idle),
            ],
            now: now
        )

        XCTAssertEqual(snapshot.sessions.map(\.threadID), ["main"])
        XCTAssertEqual(snapshot.sessions.first?.status, .ready)
    }

    func testPersistentForkRemainsAnIndependentThread() {
        let fork = CodexThread(
            id: "fork",
            name: "fork",
            updatedAt: now,
            sessionID: "fork",
            forkedFromID: "main",
            ephemeral: false,
            status: .init(kind: .idle)
        )
        let snapshot = ThreadProjector().hostSnapshot(
            hostID: "host-a",
            threads: [thread("main", .idle), fork],
            now: now
        )

        XCTAssertEqual(Set(snapshot.sessions.map(\.threadID)), ["main", "fork"])
    }

    func testOrphanedSideConversationIsSuppressed() {
        let snapshot = ThreadProjector().hostSnapshot(
            hostID: "host-a",
            threads: [
                sideThread("side", parentID: "missing", kind: .active),
            ],
            now: now
        )

        XCTAssertTrue(snapshot.sessions.isEmpty)
    }

    func testEphemeralThreadWithoutReadableParentIsSuppressed() {
        let ephemeral = CodexThread(
            id: "side",
            name: "side",
            updatedAt: now,
            sessionID: "side",
            ephemeral: true,
            status: .init(kind: .active)
        )
        let snapshot = ThreadProjector().hostSnapshot(
            hostID: "host-a",
            threads: [thread("main", .idle), ephemeral],
            now: now
        )

        XCTAssertEqual(snapshot.sessions.map(\.threadID), ["main"])
        XCTAssertEqual(snapshot.sessions.first?.status, .ready)
    }

    func testNameFallbackOrderAndTruncation() {
        let projector = ThreadProjector(maximumNameLength: 12)
        XCTAssertEqual(
            projector.displayName(
                for: CodexThread(
                    id: "id",
                    name: "  Explicit ",
                    preview: "Preview",
                    cwd: "/tmp/project",
                    status: .init(kind: .idle)
                )
            ),
            "Explicit"
        )
        XCTAssertEqual(
            projector.displayName(
                for: CodexThread(
                    id: "id",
                    preview: "\n First preview line\nsecond",
                    cwd: "/tmp/project",
                    status: .init(kind: .idle)
                )
            ),
            "First previ…"
        )
        XCTAssertEqual(
            projector.displayName(
                for: CodexThread(
                    id: "0123456789",
                    cwd: "/tmp/project",
                    status: .init(kind: .idle)
                )
            ),
            "project"
        )
        XCTAssertEqual(
            projector.displayName(
                for: CodexThread(
                    id: "0123456789",
                    status: .init(kind: .idle)
                )
            ),
            "01234567"
        )
    }

    func testDashboardSortsByGroupThenRecency() {
        let sessions = [
            SessionSnapshot(
                hostID: "h",
                threadID: "old-ready",
                name: "old",
                updatedAt: now,
                status: .ready
            ),
            SessionSnapshot(
                hostID: "h",
                threadID: "new-working",
                name: "new",
                updatedAt: now.addingTimeInterval(10),
                status: .working
            ),
            SessionSnapshot(
                hostID: "h",
                threadID: "attention",
                name: "attention",
                updatedAt: now.addingTimeInterval(-10),
                status: .needsAttention
            ),
        ]
        XCTAssertEqual(
            DashboardSnapshot(sessions: sessions).sessions.map(\.threadID),
            ["attention", "new-working", "old-ready"]
        )
    }

    private func thread(
        _ id: String,
        _ kind: CodexThreadStatusKind,
        flags: Set<String> = []
    ) -> CodexThread {
        CodexThread(
            id: id,
            name: id,
            updatedAt: now,
            sessionID: id,
            status: .init(kind: kind, activeFlags: flags)
        )
    }

    private func sideThread(
        _ id: String,
        parentID: String,
        kind: CodexThreadStatusKind,
        flags: Set<String> = []
    ) -> CodexThread {
        CodexThread(
            id: id,
            name: id,
            updatedAt: now.addingTimeInterval(1),
            sessionID: id,
            forkedFromID: parentID,
            ephemeral: true,
            status: .init(kind: kind, activeFlags: flags)
        )
    }
}
