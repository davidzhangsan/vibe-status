import Darwin
import Foundation

public struct SSHPipeDescriptors: Equatable, Sendable {
    /// A duplicated descriptor from which the caller reads SSH stdout.
    public let readDescriptor: Int32

    /// A duplicated descriptor to which the caller writes SSH stdin.
    public let writeDescriptor: Int32

    public init(readDescriptor: Int32, writeDescriptor: Int32) {
        self.readDescriptor = readDescriptor
        self.writeDescriptor = writeDescriptor
    }
}

public struct SSHProcessTermination: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case exit
        case uncaughtSignal
    }

    public let status: Int32
    public let reason: Reason

    public init(status: Int32, reason: Reason) {
        self.status = status
        self.reason = reason
    }
}

public enum SSHProcessTransportError: Error, Equatable, LocalizedError {
    case alreadyRunning
    case notRunning
    case descriptorDuplicationFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "The SSH process is already running."
        case .notRunning:
            return "The SSH process is not running."
        case let .descriptorDuplicationFailed(errorNumber):
            return "Could not duplicate an SSH pipe descriptor (errno \(errorNumber))."
        }
    }
}

public protocol SSHByteTransporting: AnyObject, Sendable {
    var diagnostics: BoundedDiagnosticRing { get }
    var isRunning: Bool { get }

    func start() throws
    func duplicatePipeDescriptors() throws -> SSHPipeDescriptors
    func stop()
}

/// Owns exactly one local `/usr/bin/ssh` child process.
///
/// No shell is used locally. The protocol layer should call
/// `duplicatePipeDescriptors()` and let its event loop take ownership of the
/// returned descriptors.
public final class SSHProcessTransport: SSHByteTransporting, @unchecked Sendable {
    public let profile: HostProfile
    public let launchPlan: SSHLaunchPlan
    public let diagnostics: BoundedDiagnosticRing

    private let lock = NSLock()
    private let onTermination: @Sendable (SSHProcessTermination) -> Void

    private var process: Process?
    private var standardInputWriter: FileHandle?
    private var standardOutputReader: FileHandle?
    private var standardErrorReader: FileHandle?

    public init(
        profile: HostProfile,
        diagnostics: BoundedDiagnosticRing = BoundedDiagnosticRing(),
        onTermination: @escaping @Sendable (SSHProcessTermination) -> Void = { _ in }
    ) throws {
        self.profile = profile
        self.launchPlan = try SSHCommandBuilder.launchPlan(for: profile)
        self.diagnostics = diagnostics
        self.onTermination = onTermination
    }

    public var isRunning: Bool {
        lock.withLock { process?.isRunning == true }
    }

    public var processIdentifier: Int32? {
        lock.withLock {
            guard let process, process.isRunning else { return nil }
            return process.processIdentifier
        }
    }

    public func start() throws {
        let child = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()

        child.executableURL = launchPlan.executableURL
        child.arguments = launchPlan.arguments
        child.standardInput = standardInput.fileHandleForReading
        child.standardOutput = standardOutput.fileHandleForWriting
        child.standardError = standardError.fileHandleForWriting

        child.terminationHandler = { [weak self] terminatedProcess in
            self?.processDidTerminate(terminatedProcess)
        }

        standardError.fileHandleForReading.readabilityHandler = { [weak diagnostics] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                diagnostics?.append(data)
            }
        }

        try lock.withLock {
            guard process == nil else {
                throw SSHProcessTransportError.alreadyRunning
            }

            process = child
            standardInputWriter = standardInput.fileHandleForWriting
            standardOutputReader = standardOutput.fileHandleForReading
            standardErrorReader = standardError.fileHandleForReading
        }

        do {
            try child.run()

            // The spawned child has duplicated these ends. Closing the parent's
            // copies is required for reliable EOF delivery.
            try? standardInput.fileHandleForReading.close()
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
        } catch {
            standardError.fileHandleForReading.readabilityHandler = nil
            closeParentHandles()
            lock.withLock {
                if process === child {
                    process = nil
                }
            }
            throw error
        }
    }

    public func duplicatePipeDescriptors() throws -> SSHPipeDescriptors {
        try lock.withLock {
            guard
                let process,
                process.isRunning,
                let standardOutputReader,
                let standardInputWriter
            else {
                throw SSHProcessTransportError.notRunning
            }

            let readDescriptor = Darwin.dup(standardOutputReader.fileDescriptor)
            guard readDescriptor >= 0 else {
                throw SSHProcessTransportError.descriptorDuplicationFailed(errno)
            }

            let writeDescriptor = Darwin.dup(standardInputWriter.fileDescriptor)
            guard writeDescriptor >= 0 else {
                let savedError = errno
                Darwin.close(readDescriptor)
                throw SSHProcessTransportError.descriptorDuplicationFailed(savedError)
            }

            return SSHPipeDescriptors(
                readDescriptor: readDescriptor,
                writeDescriptor: writeDescriptor
            )
        }
    }

    public func stop() {
        let child = lock.withLock { process }
        if child?.isRunning == true {
            child?.terminate()
        }

        // Closing stdin lets ssh exit naturally if it is already winding down.
        lock.withLock {
            try? standardInputWriter?.close()
            standardInputWriter = nil
        }
    }

    private func processDidTerminate(_ terminatedProcess: Process) {
        let termination = SSHProcessTermination(
            status: terminatedProcess.terminationStatus,
            reason: terminatedProcess.terminationReason == .exit
                ? .exit
                : .uncaughtSignal
        )

        lock.withLock {
            guard process === terminatedProcess else { return }
            process = nil
        }
        closeParentHandles()
        onTermination(termination)
    }

    private func closeParentHandles() {
        let handles = lock.withLock { () -> (FileHandle?, FileHandle?, FileHandle?) in
            let handles = (
                standardInputWriter,
                standardOutputReader,
                standardErrorReader
            )
            standardInputWriter = nil
            standardOutputReader = nil
            standardErrorReader = nil
            return handles
        }

        handles.2?.readabilityHandler = nil
        try? handles.0?.close()
        try? handles.1?.close()
        try? handles.2?.close()
    }

    deinit {
        stop()
        closeParentHandles()
    }
}

public struct SSHProcessLauncher: Sendable {
    public init() {}

    public func makeTransport(
        profile: HostProfile,
        diagnostics: BoundedDiagnosticRing = BoundedDiagnosticRing(),
        onTermination: @escaping @Sendable (SSHProcessTermination) -> Void = { _ in }
    ) throws -> SSHProcessTransport {
        try SSHProcessTransport(
            profile: profile,
            diagnostics: diagnostics,
            onTermination: onTermination
        )
    }

    @discardableResult
    public func launch(
        profile: HostProfile,
        diagnostics: BoundedDiagnosticRing = BoundedDiagnosticRing(),
        onTermination: @escaping @Sendable (SSHProcessTermination) -> Void = { _ in }
    ) throws -> SSHProcessTransport {
        let transport = try makeTransport(
            profile: profile,
            diagnostics: diagnostics,
            onTermination: onTermination
        )
        try transport.start()
        return transport
    }
}
