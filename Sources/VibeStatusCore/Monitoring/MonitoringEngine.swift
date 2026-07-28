import Foundation

/// Merges independently replaceable host snapshots. Counts are always derived
/// from the merged session collection, never incremented as separate state.
public actor MonitoringEngine {
    private var hosts: [String: HostSnapshot] = [:]
    private var continuations:
        [UUID: AsyncStream<DashboardSnapshot>.Continuation] = [:]

    public init() {}

    public func currentSnapshot() -> DashboardSnapshot {
        makeDashboardSnapshot()
    }

    public func snapshots() -> AsyncStream<DashboardSnapshot> {
        let identifier = UUID()
        let pair = AsyncStream<DashboardSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuations[identifier] = pair.continuation
        pair.continuation.yield(makeDashboardSnapshot())
        pair.continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeContinuation(identifier)
            }
        }
        return pair.stream
    }

    public func replaceHost(_ snapshot: HostSnapshot) {
        hosts[snapshot.hostID] = HostSnapshot(
            hostID: snapshot.hostID,
            sessions: snapshot.sessions.filter { $0.hostID == snapshot.hostID },
            issues: snapshot.issues.filter { $0.hostID == snapshot.hostID }
        )
        publish()
    }

    public func markHostDisconnected(
        hostID: String,
        message: String,
        at date: Date = Date()
    ) {
        hosts[hostID] = .init(
            hostID: hostID,
            sessions: [],
            issues: [
                .init(
                    hostID: hostID,
                    kind: .disconnected,
                    message: message,
                    updatedAt: date
                ),
            ]
        )
        publish()
    }

    public func removeHost(_ hostID: String) {
        hosts.removeValue(forKey: hostID)
        publish()
    }

    private func makeDashboardSnapshot() -> DashboardSnapshot {
        DashboardSnapshot(
            sessions: hosts.values.flatMap(\.sessions),
            issues: hosts.values.flatMap(\.issues)
        )
    }

    private func publish() {
        let snapshot = makeDashboardSnapshot()
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}
