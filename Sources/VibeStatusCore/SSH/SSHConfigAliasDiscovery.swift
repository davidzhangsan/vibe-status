import Darwin
import Foundation

public struct SSHConfigAliasDiscovery {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory.standardizedFileURL
    }

    /// Returns concrete `Host` aliases in first-seen order.
    ///
    /// Wildcard and negated patterns are intentionally omitted because they
    /// cannot be selected as deterministic remote-host destinations.
    public func discover(from configURL: URL? = nil) throws -> [String] {
        let rootURL = (
            configURL ?? homeDirectory.appendingPathComponent(".ssh/config")
        ).standardizedFileURL

        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return []
        }

        var visited = Set<URL>()
        var aliases: [String] = []
        var seenAliases = Set<String>()
        try parse(
            rootURL,
            visited: &visited,
            aliases: &aliases,
            seenAliases: &seenAliases,
            isRoot: true
        )
        return aliases
    }

    private func parse(
        _ fileURL: URL,
        visited: inout Set<URL>,
        aliases: inout [String],
        seenAliases: inout Set<String>,
        isRoot: Bool
    ) throws {
        let canonicalURL = fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard visited.insert(canonicalURL).inserted else { return }

        let contents: String
        do {
            contents = try String(contentsOf: canonicalURL, encoding: .utf8)
        } catch {
            if isRoot {
                throw error
            }
            return
        }

        for line in contents.split(whereSeparator: \.isNewline) {
            let tokens = Self.tokens(in: String(line))
            guard !tokens.isEmpty else { continue }

            let directive = Self.directiveAndArguments(tokens)
            switch directive.keyword.lowercased() {
            case "host":
                for candidate in directive.arguments where Self.isLiteralAlias(candidate) {
                    guard SSHInputValidator.isValidAlias(candidate) else { continue }
                    if seenAliases.insert(candidate).inserted {
                        aliases.append(candidate)
                    }
                }

            case "include":
                for pattern in directive.arguments {
                    let includeURLs = expandedIncludeURLs(
                        pattern,
                        relativeTo: canonicalURL.deletingLastPathComponent()
                    )
                    for includeURL in includeURLs {
                        try parse(
                            includeURL,
                            visited: &visited,
                            aliases: &aliases,
                            seenAliases: &seenAliases,
                            isRoot: false
                        )
                    }
                }

            default:
                continue
            }
        }
    }

    private func expandedIncludeURLs(_ rawPattern: String, relativeTo directory: URL) -> [URL] {
        let expandedPath: String
        if rawPattern == "~" {
            expandedPath = homeDirectory.path
        } else if rawPattern.hasPrefix("~/") {
            expandedPath = homeDirectory
                .appendingPathComponent(String(rawPattern.dropFirst(2)))
                .path
        } else if rawPattern == "$HOME" {
            expandedPath = homeDirectory.path
        } else if rawPattern.hasPrefix("$HOME/") {
            expandedPath = homeDirectory
                .appendingPathComponent(String(rawPattern.dropFirst("$HOME/".count)))
                .path
        } else if rawPattern.hasPrefix("/") {
            expandedPath = rawPattern
        } else {
            expandedPath = directory.appendingPathComponent(rawPattern).path
        }

        return Self.expandGlob(expandedPath)
    }

    private static func expandGlob(_ absolutePattern: String) -> [URL] {
        let components = (absolutePattern as NSString).pathComponents
        guard components.first == "/" else { return [] }

        var candidates = [URL(fileURLWithPath: "/", isDirectory: true)]
        for component in components.dropFirst() {
            if containsGlob(component) {
                var matches: [URL] = []
                for directory in candidates {
                    let entries = (try? FileManager.default.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: []
                    )) ?? []
                    matches.append(contentsOf: entries.filter { entry in
                        let name = entry.lastPathComponent
                        guard !name.hasPrefix(".") || component.hasPrefix(".") else {
                            return false
                        }
                        return component.withCString { patternPointer in
                            name.withCString { namePointer in
                                fnmatch(patternPointer, namePointer, 0) == 0
                            }
                        }
                    })
                }
                candidates = matches.sorted { $0.path < $1.path }
            } else {
                candidates = candidates.map { $0.appendingPathComponent(component) }
            }
        }

        return candidates
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.standardizedFileURL)
    }

    private static func containsGlob(_ component: String) -> Bool {
        component.contains("*") || component.contains("?") || component.contains("[")
    }

    private static func isLiteralAlias(_ candidate: String) -> Bool {
        !candidate.hasPrefix("!")
            && !containsGlob(candidate)
            && !candidate.contains("%")
    }

    private static func directiveAndArguments(
        _ tokens: [String]
    ) -> (keyword: String, arguments: [String]) {
        guard let equalsIndex = tokens[0].firstIndex(of: "=") else {
            return (tokens[0], Array(tokens.dropFirst()))
        }

        let keyword = String(tokens[0][..<equalsIndex])
        let inlineArgument = String(tokens[0][tokens[0].index(after: equalsIndex)...])
        var arguments = inlineArgument.isEmpty ? [] : [inlineArgument]
        arguments.append(contentsOf: tokens.dropFirst())
        return (keyword, arguments)
    }

    /// A deliberately small ssh_config lexer supporting quotes, escapes, and
    /// comments. Environment or command expansion is never performed.
    private static func tokens(in line: String) -> [String] {
        var result: [String] = []
        var token = ""
        var quote: Character?
        var isEscaping = false
        var tokenStarted = false

        func finishToken() {
            if tokenStarted {
                result.append(token)
                token = ""
                tokenStarted = false
            }
        }

        for character in line {
            if isEscaping {
                token.append(character)
                tokenStarted = true
                isEscaping = false
                continue
            }

            if character == "\\" {
                isEscaping = true
                tokenStarted = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    token.append(character)
                }
                tokenStarted = true
                continue
            }

            if character == "\"" || character == "'" {
                quote = character
                tokenStarted = true
            } else if character == "#" {
                break
            } else if character.isWhitespace {
                finishToken()
            } else {
                token.append(character)
                tokenStarted = true
            }
        }

        if isEscaping {
            token.append("\\")
        }
        finishToken()
        return result
    }
}
