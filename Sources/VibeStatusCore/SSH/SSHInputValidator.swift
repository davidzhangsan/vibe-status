import Foundation

public enum SSHInputValidationError: Error, Equatable, LocalizedError {
    case emptyAlias
    case invalidAlias(String)
    case emptyExecutablePath
    case executablePathMustBeAbsoluteOrHomeRelative
    case invalidExecutablePathCharacter(Character)
    case unsafeControlCharacter

    public var errorDescription: String? {
        switch self {
        case .emptyAlias:
            return "Enter an SSH config alias."
        case let .invalidAlias(alias):
            return "“\(alias)” is not a valid SSH config alias."
        case .emptyExecutablePath:
            return "Enter the remote Codex executable path."
        case .executablePathMustBeAbsoluteOrHomeRelative:
            return "The Codex path must be absolute or start with $HOME/."
        case let .invalidExecutablePathCharacter(character):
            return "The Codex path contains the unsupported character “\(character)”."
        case .unsafeControlCharacter:
            return "Newlines and NUL characters are not allowed."
        }
    }
}

public enum RemoteExecutablePath: Equatable, Sendable {
    case absolute(String)
    case homeRelative(String)

    public var rawValue: String {
        switch self {
        case let .absolute(path):
            return path
        case let .homeRelative(path):
            return "$HOME/\(path)"
        }
    }
}

public enum SSHInputValidator {
    private static let pathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._+-@%:,="
    )

    public static func validateAlias(_ alias: String) throws {
        guard !alias.isEmpty else {
            throw SSHInputValidationError.emptyAlias
        }

        let scalars = alias.unicodeScalars
        guard
            let first = scalars.first,
            isASCIIAlphaNumeric(first),
            scalars.dropFirst().allSatisfy({ isASCIIAlphaNumeric($0) || "._-".unicodeScalars.contains($0) })
        else {
            throw SSHInputValidationError.invalidAlias(alias)
        }
    }

    public static func isValidAlias(_ alias: String) -> Bool {
        do {
            try validateAlias(alias)
            return true
        } catch {
            return false
        }
    }

    public static func parseExecutablePath(_ path: String) throws -> RemoteExecutablePath {
        guard !path.isEmpty else {
            throw SSHInputValidationError.emptyExecutablePath
        }
        guard !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw SSHInputValidationError.unsafeControlCharacter
        }

        let parsed: RemoteExecutablePath
        let pathToValidate: Substring
        if path.hasPrefix("$HOME/") {
            pathToValidate = path.dropFirst("$HOME/".count)
            guard !pathToValidate.isEmpty else {
                throw SSHInputValidationError.emptyExecutablePath
            }
            parsed = .homeRelative(String(pathToValidate))
        } else if path.hasPrefix("/") {
            pathToValidate = path.dropFirst()
            guard !pathToValidate.isEmpty else {
                throw SSHInputValidationError.emptyExecutablePath
            }
            parsed = .absolute(path)
        } else {
            throw SSHInputValidationError.executablePathMustBeAbsoluteOrHomeRelative
        }

        for scalar in pathToValidate.unicodeScalars where !pathCharacters.contains(scalar) {
            throw SSHInputValidationError.invalidExecutablePathCharacter(Character(String(scalar)))
        }
        return parsed
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48 ... 57, 65 ... 90, 97 ... 122:
            return true
        default:
            return false
        }
    }
}
