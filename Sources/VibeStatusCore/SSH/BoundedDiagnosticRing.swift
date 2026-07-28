import Foundation

/// A thread-safe, in-memory stderr buffer.
///
/// The ring intentionally stores raw bytes so a multi-byte UTF-8 scalar split
/// across reads is decoded only when a snapshot is requested.
public final class BoundedDiagnosticRing: @unchecked Sendable {
    public let maximumBytes: Int
    public let maximumLines: Int

    private let lock = NSLock()
    private var storage = Data()

    public init(maximumBytes: Int = 64 * 1_024, maximumLines: Int = 100) {
        precondition(maximumBytes > 0)
        precondition(maximumLines > 0)
        self.maximumBytes = maximumBytes
        self.maximumLines = maximumLines
    }

    public func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.withLock {
            storage.append(data)
            trimToByteLimit()
            trimToLineLimit()
        }
    }

    public func append(_ text: String) {
        append(Data(text.utf8))
    }

    public func snapshotData() -> Data {
        lock.withLock { storage }
    }

    public func snapshotText() -> String {
        String(decoding: snapshotData(), as: UTF8.self)
    }

    public func snapshotLines() -> [String] {
        snapshotText()
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    public func clear() {
        lock.withLock {
            storage.removeAll(keepingCapacity: true)
        }
    }

    private func trimToByteLimit() {
        guard storage.count > maximumBytes else { return }
        storage.removeFirst(storage.count - maximumBytes)
    }

    private func trimToLineLimit() {
        var newlineOffsets: [Int] = []
        newlineOffsets.reserveCapacity(maximumLines + 1)
        for (offset, byte) in storage.enumerated() where byte == 0x0A {
            newlineOffsets.append(offset)
        }

        let hasPartialLastLine = storage.last != 0x0A
        let lineCount = newlineOffsets.count + (hasPartialLastLine ? 1 : 0)
        let linesToDrop = lineCount - maximumLines
        guard linesToDrop > 0 else { return }

        let firstRetainedLineOffset = newlineOffsets[linesToDrop - 1] + 1
        storage.removeFirst(firstRetainedLineOffset)
    }
}
