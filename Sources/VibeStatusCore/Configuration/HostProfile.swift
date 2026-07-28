import Foundation

public struct HostProfile: Codable, Hashable, Identifiable, Sendable {
    /// An empty path asks onboarding to discover Codex on the remote host.
    public static let automaticCodexPath = ""
    public static let suggestedCodexPath = "$HOME/.local/bin/codex"

    public var id: UUID
    public var alias: String
    public var displayName: String
    public var codexPath: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        alias: String,
        displayName: String? = nil,
        codexPath: String = HostProfile.automaticCodexPath,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.alias = alias
        self.displayName = displayName ?? alias
        self.codexPath = codexPath
        self.isEnabled = isEnabled
    }
}

public struct VibeStatusPreferences: Codable, Equatable, Sendable {
    public var launchAtLogin: Bool

    public init(launchAtLogin: Bool = false) {
        self.launchAtLogin = launchAtLogin
    }
}

public struct VibeStatusConfiguration: Codable, Equatable, Sendable {
    public var hosts: [HostProfile]
    public var preferences: VibeStatusPreferences

    public init(
        hosts: [HostProfile],
        preferences: VibeStatusPreferences = VibeStatusPreferences()
    ) {
        self.hosts = hosts
        self.preferences = preferences
    }

    public static let empty = VibeStatusConfiguration(hosts: [])
}
