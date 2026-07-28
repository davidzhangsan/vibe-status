import Foundation

public struct ReconnectPolicy: Sendable, Hashable {
    public let delays: [TimeInterval]
    public let jitterFraction: Double
    public let stableConnectionResetInterval: TimeInterval

    public init(
        delays: [TimeInterval] = [1, 2, 4, 8, 15, 30],
        jitterFraction: Double = 0.2,
        stableConnectionResetInterval: TimeInterval = 60
    ) {
        self.delays = delays.isEmpty ? [1] : delays.map { max(0, $0) }
        self.jitterFraction = min(max(jitterFraction, 0), 1)
        self.stableConnectionResetInterval = max(0, stableConnectionResetInterval)
    }

    /// `failureCount` is one-based. `jitterUnit` is clamped to -1...1 so tests
    /// and callers can deterministically choose the lower, center, or upper
    /// edge of the jitter window.
    public func delay(
        forFailureCount failureCount: Int,
        jitterUnit: Double
    ) -> TimeInterval {
        let index = min(max(failureCount - 1, 0), delays.count - 1)
        let unit = min(max(jitterUnit, -1), 1)
        return delays[index] * (1 + unit * jitterFraction)
    }
}

public struct ReconcilePolicy: Sendable, Hashable {
    public let interval: TimeInterval
    public let jitterFraction: Double
    public let pageSize: Int
    public let readConcurrency: Int

    public init(
        interval: TimeInterval = 15,
        jitterFraction: Double = 0.15,
        pageSize: Int = 100,
        readConcurrency: Int = 8
    ) {
        self.interval = max(0.1, interval)
        self.jitterFraction = min(max(jitterFraction, 0), 1)
        self.pageSize = max(1, pageSize)
        self.readConcurrency = max(1, readConcurrency)
    }

    public func delay(jitterUnit: Double) -> TimeInterval {
        let unit = min(max(jitterUnit, -1), 1)
        return interval * (1 + unit * jitterFraction)
    }
}
