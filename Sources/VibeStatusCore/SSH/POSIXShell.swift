import Foundation

public enum POSIXShell {
    /// Produces one literal POSIX shell word.
    public static func quote(_ value: String) throws -> String {
        guard !value.contains("\0"), !value.contains("\n"), !value.contains("\r") else {
            throw SSHInputValidationError.unsafeControlCharacter
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public static func renderExecutablePath(_ rawPath: String) throws -> String {
        switch try SSHInputValidator.parseExecutablePath(rawPath) {
        case let .absolute(path):
            return try quote(path)
        case let .homeRelative(relativePath):
            return "\"$HOME\"/" + (try quote(relativePath))
        }
    }
}
