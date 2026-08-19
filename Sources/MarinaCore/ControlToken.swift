import Foundation
import Security

/// Shared secret for the local control API.
///
/// The API can read every server environment and start commands, so reaching the
/// loopback port is not by itself proof of authorization. The token is generated
/// on first launch and stored in `~/.config/marina/token` with mode 0600, so a
/// caller must be able to read this user's files to drive the privileged routes.
public enum ControlToken {
    /// Overrides the token file. Useful for a CLI run under a different HOME.
    public static let environmentKey = "MARINA_TOKEN"

    /// The token a client should present: the environment wins, then the file.
    public static func current() -> String? {
        if let injected = ProcessInfo.processInfo.environment[environmentKey],
           !injected.isEmpty {
            return injected
        }
        return read()
    }

    public static func read(from url: URL = MarinaPaths.tokenFile) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Returns the existing token, or writes a fresh one. Called by the app as it
    /// starts the control server.
    @discardableResult
    public static func loadOrCreate(at url: URL = MarinaPaths.tokenFile) -> String {
        if let existing = read(from: url) { return existing }
        let token = generate()
        write(token, to: url)
        return token
    }

    static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // Swift's default generator is also seeded from the system CSPRNG.
            bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func write(_ token: String, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Create the file with its final mode instead of widening it first.
        try? fm.removeItem(at: url)
        fm.createFile(
            atPath: url.path,
            contents: Data(token.utf8),
            attributes: [.posixPermissions: 0o600]
        )
    }

    /// Compares in time independent of where the two values first differ, so a
    /// rejected token leaks nothing through response timing.
    public static func matches(_ candidate: String, _ expected: String) -> Bool {
        let presented = Array(candidate.utf8)
        let reference = Array(expected.utf8)
        var difference = presented.count ^ reference.count
        for index in 0..<max(presented.count, reference.count) {
            let left = index < presented.count ? Int(presented[index]) : 0
            let right = index < reference.count ? Int(reference[index]) : 0
            difference |= left ^ right
        }
        return difference == 0
    }
}
