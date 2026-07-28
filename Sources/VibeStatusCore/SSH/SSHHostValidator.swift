import Foundation

public struct SSHCommandResult: Equatable, Sendable {
    public let termination: SSHProcessTermination
    public let standardOutput: Data
    public let standardError: Data

    public init(
        termination: SSHProcessTermination,
        standardOutput: Data,
        standardError: Data
    ) {
        self.termination = termination
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var standardOutputText: String {
        String(decoding: standardOutput, as: UTF8.self)
    }

    public var standardErrorText: String {
        String(decoding: standardError, as: UTF8.self)
    }
}

public enum SSHCommandRunnerError: Error, Equatable, LocalizedError {
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "The SSH command timed out."
        }
    }
}

public struct SSHOneShotCommandRunner: Sendable {
    public let timeout: TimeInterval
    public let maximumOutputBytesPerStream: Int

    public init(
        timeout: TimeInterval = 20,
        maximumOutputBytesPerStream: Int = 1_048_576
    ) {
        precondition(timeout > 0)
        precondition(maximumOutputBytesPerStream > 0)
        self.timeout = timeout
        self.maximumOutputBytesPerStream = maximumOutputBytesPerStream
    }

    public func run(_ plan: SSHLaunchPlan) async throws -> SSHCommandResult {
        try await Task.detached(priority: .utility) {
            try runBlocking(plan)
        }.value
    }

    private func runBlocking(_ plan: SSHLaunchPlan) throws -> SSHCommandResult {
        let child = Process()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        child.executableURL = plan.executableURL
        child.arguments = plan.arguments
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = standardOutputPipe.fileHandleForWriting
        child.standardError = standardErrorPipe.fileHandleForWriting

        try child.run()
        try? standardOutputPipe.fileHandleForWriting.close()
        try? standardErrorPipe.fileHandleForWriting.close()

        let standardOutput = BoundedDiagnosticRing(
            maximumBytes: maximumOutputBytesPerStream,
            maximumLines: 10_000
        )
        let standardError = BoundedDiagnosticRing(
            maximumBytes: maximumOutputBytesPerStream,
            maximumLines: 10_000
        )
        let readers = DispatchGroup()
        Self.drain(
            standardOutputPipe.fileHandleForReading,
            into: standardOutput,
            group: readers
        )
        Self.drain(
            standardErrorPipe.fileHandleForReading,
            into: standardError,
            group: readers
        )

        let timeoutFlag = LockedFlag()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            guard child.isRunning else { return }
            timeoutFlag.set()
            child.terminate()
        }
        timer.resume()

        child.waitUntilExit()
        timer.cancel()
        readers.wait()

        try? standardOutputPipe.fileHandleForReading.close()
        try? standardErrorPipe.fileHandleForReading.close()

        if timeoutFlag.value {
            throw SSHCommandRunnerError.timedOut
        }

        return SSHCommandResult(
            termination: SSHProcessTermination(
                status: child.terminationStatus,
                reason: child.terminationReason == .exit ? .exit : .uncaughtSignal
            ),
            standardOutput: standardOutput.snapshotData(),
            standardError: standardError.snapshotData()
        )
    }

    private static func drain(
        _ handle: FileHandle,
        into buffer: BoundedDiagnosticRing,
        group: DispatchGroup
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                do {
                    guard
                        let data = try handle.read(upToCount: 4_096),
                        !data.isEmpty
                    else {
                        return
                    }
                    buffer.append(data)
                } catch {
                    return
                }
            }
        }
    }
}

public struct SSHHostValidation: Equatable, Sendable {
    public let codexVersion: String
    public let daemonVersion: String
    public let diagnostics: String
    public let resolvedCodexPath: String

    public init(
        codexVersion: String,
        daemonVersion: String,
        diagnostics: String,
        resolvedCodexPath: String
    ) {
        self.codexVersion = codexVersion
        self.daemonVersion = daemonVersion
        self.diagnostics = diagnostics
        self.resolvedCodexPath = resolvedCodexPath
    }
}

public enum SSHHostValidatorError: Error, Equatable, LocalizedError {
    case configurationInspectionFailed(status: Int32, diagnostics: String)
    case connectionFailed(alias: String, diagnostics: String)
    case codexDiscoveryFailed(status: Int32, diagnostics: String)
    case codexVersionFailed(status: Int32, diagnostics: String)
    case daemonCapabilityFailed(status: Int32, diagnostics: String)

    public var errorDescription: String? {
        switch self {
        case let .configurationInspectionFailed(_, diagnostics):
            return Self.message(
                prefix: "OpenSSH could not resolve this alias.",
                diagnostics: diagnostics
            )
        case let .connectionFailed(alias, diagnostics):
            return Self.message(
                prefix: "SSH could not connect non-interactively. Run “ssh \(alias)” once in Terminal, then retry.",
                diagnostics: diagnostics
            )
        case let .codexDiscoveryFailed(_, diagnostics):
            return Self.message(
                prefix: "Codex was not found automatically. Enter its absolute path for this remote host.",
                diagnostics: diagnostics
            )
        case let .codexVersionFailed(_, diagnostics):
            return Self.message(
                prefix: "Codex was not executable at the configured path.",
                diagnostics: diagnostics
            )
        case let .daemonCapabilityFailed(_, diagnostics):
            return Self.message(
                prefix: "This Codex installation does not expose the required app-server daemon.",
                diagnostics: diagnostics
            )
        }
    }

    private static func message(prefix: String, diagnostics: String) -> String {
        let detail = diagnostics.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? prefix : "\(prefix) \(detail)"
    }
}

public struct SSHHostValidator: Sendable {
    private let runner: SSHOneShotCommandRunner

    public init(runner: SSHOneShotCommandRunner = SSHOneShotCommandRunner()) {
        self.runner = runner
    }

    public func validate(_ profile: HostProfile) async throws -> SSHHostValidation {
        let inspection = try await runner.run(
            SSHCommandBuilder.configurationInspectionPlan(alias: profile.alias)
        )
        guard inspection.termination.status == 0 else {
            throw SSHHostValidatorError.configurationInspectionFailed(
                status: inspection.termination.status,
                diagnostics: inspection.standardErrorText
            )
        }

        var resolvedProfile = profile
        var discovery: SSHCommandResult?
        if profile.codexPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            let result = try await runner.run(
                SSHCommandBuilder.codexDiscoveryProbePlan(alias: profile.alias)
            )
            discovery = result
            if result.termination.status == 255 {
                throw SSHHostValidatorError.connectionFailed(
                    alias: profile.alias,
                    diagnostics: result.standardErrorText
                )
            }
            guard
                result.termination.status == 0,
                let resolvedPath = Self.resolvedCodexPath(
                    in: result.standardOutputText
                )
            else {
                throw SSHHostValidatorError.codexDiscoveryFailed(
                    status: result.termination.status,
                    diagnostics: result.standardErrorText
                )
            }
            resolvedProfile.codexPath = resolvedPath
        }

        let codex = try await runner.run(
            SSHCommandBuilder.codexVersionProbePlan(for: resolvedProfile)
        )
        if codex.termination.status == 255 {
            throw SSHHostValidatorError.connectionFailed(
                alias: profile.alias,
                diagnostics: codex.standardErrorText
            )
        }
        guard codex.termination.status == 0 else {
            throw SSHHostValidatorError.codexVersionFailed(
                status: codex.termination.status,
                diagnostics: codex.standardErrorText
            )
        }

        let daemonCapability = try await runner.run(
            SSHCommandBuilder.daemonCapabilityProbePlan(for: resolvedProfile)
        )
        if daemonCapability.termination.status == 255 {
            throw SSHHostValidatorError.connectionFailed(
                alias: profile.alias,
                diagnostics: daemonCapability.standardErrorText
            )
        }
        guard daemonCapability.termination.status == 0 else {
            throw SSHHostValidatorError.daemonCapabilityFailed(
                status: daemonCapability.termination.status,
                diagnostics: daemonCapability.standardErrorText
            )
        }

        let daemon = try await runner.run(
            SSHCommandBuilder.daemonVersionProbePlan(for: resolvedProfile)
        )
        if daemon.termination.status == 255 {
            throw SSHHostValidatorError.connectionFailed(
                alias: profile.alias,
                diagnostics: daemon.standardErrorText
            )
        }
        var validationResults = [inspection]
        if let discovery {
            validationResults.append(discovery)
        }
        validationResults.append(contentsOf: [codex, daemonCapability, daemon])
        let diagnosticText = validationResults
            .map(\.standardErrorText)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let daemonVersion = daemon.termination.status == 0
            ? daemon.standardOutputText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : "Daemon is not running; it will be started when monitoring begins."

        return SSHHostValidation(
            codexVersion: codex.standardOutputText
                .trimmingCharacters(in: .whitespacesAndNewlines),
            daemonVersion: daemonVersion,
            diagnostics: diagnosticText,
            resolvedCodexPath: resolvedProfile.codexPath
        )
    }

    static func resolvedCodexPath(in output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline).reversed() {
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                let parsed = try? SSHInputValidator.parseExecutablePath(candidate),
                case .absolute = parsed
            else {
                continue
            }
            return candidate
        }
        return nil
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.withLock { storage }
    }

    func set() {
        lock.withLock {
            storage = true
        }
    }
}
