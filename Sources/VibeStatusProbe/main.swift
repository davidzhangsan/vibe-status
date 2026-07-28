import Darwin
import Foundation
import VibeStatusCore

@main
enum VibeStatusProbe {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let alias = arguments.first else {
            fputs(
                "usage: vibe-status-probe <ssh-config-alias> [remote-codex-path]\n",
                stderr
            )
            exit(64)
        }
        var profile = HostProfile(
            alias: alias,
            codexPath: arguments.dropFirst().first
                ?? HostProfile.automaticCodexPath
        )

        var client: CodexRPCClient?
        do {
            let validation = try await SSHHostValidator().validate(profile)
            profile.codexPath = validation.resolvedCodexPath
            let transport = NIOWebSocketTextTransport(profile: profile)
            let rpcClient = CodexRPCClient(
                transport: transport,
                clientInformation: .init(
                    name: "vibe_status_probe",
                    title: "Vibe Status Swift transport probe",
                    version: "0.1.0"
                )
            )
            client = rpcClient
            try await rpcClient.connectAndInitialize()
            var identifiers: [String] = []
            var cursor: String?
            repeat {
                let page = try await rpcClient.loadedThreads(
                    cursor: cursor,
                    limit: 100
                )
                identifiers.append(contentsOf: page.data)
                cursor = page.nextCursor
            } while cursor != nil

            var threads: [CodexThread] = []
            for identifier in identifiers {
                try await rpcClient.unsubscribe(threadID: identifier)
                threads.append(try await rpcClient.readThread(id: identifier))
            }

            let snapshot = ThreadProjector().hostSnapshot(
                hostID: alias,
                threads: threads
            )
            let output: [String: Any] = [
                "alias": alias,
                "loadedThreads": identifiers.count,
                "rootSessions": snapshot.sessions.count,
                "issues": snapshot.issues.count,
                "needsAttention": snapshot.sessions.filter {
                    $0.status == .needsAttention
                }.count,
                "working": snapshot.sessions.filter {
                    $0.status == .working
                }.count,
                "ready": snapshot.sessions.filter {
                    $0.status == .ready
                }.count,
                "serverRequestsAnswered": 0,
            ]
            let data = try JSONSerialization.data(
                withJSONObject: output,
                options: [.prettyPrinted, .sortedKeys]
            )
            print(String(decoding: data, as: UTF8.self))
            await rpcClient.close()
            client = nil
        } catch {
            if let client {
                await client.close()
            }
            fputs("Swift transport probe failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
