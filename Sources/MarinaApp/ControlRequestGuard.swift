import Foundation
import MarinaCore

/// Decides whether a request reaching the control API is allowed to run.
///
/// Binding to 127.0.0.1 keeps the API off the network, but it does not make the
/// loopback interface a trust boundary: the browser the user is running lives
/// there too, and a page it loads can post to a fixed local port. This guard
/// closes that path first, then requires the shared token for anything that
/// exposes secrets or starts a command.
struct ControlRequestGuard {
    struct Rejection: Equatable {
        let status: Int
        let message: String
    }

    /// Routes the sandboxed App Store companion needs. They cannot read an
    /// environment, a log, or run a new command: at worst they start or stop a
    /// command this user already configured. Everything else needs the token.
    static let tokenFreePaths: Set<String> = ["/ping", "/status", "/start", "/stop", "/restart"]

    let port: Int
    let token: String

    private var allowedHosts: Set<String> {
        var hosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        // A client omits the port only when it is the scheme default.
        if port == 80 { hosts.formUnion(["127.0.0.1", "localhost", "[::1]"]) }
        return hosts
    }

    func rejection(for request: HTTPRequest) -> Rejection? {
        // No first-party client sends any of these. A browser sends at least one
        // on every request it originates, whichever tag the page uses.
        for header in ["origin", "cookie", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest"] {
            if request.headers[header] != nil {
                return Rejection(
                    status: 403,
                    message: "Browser-originated requests are refused. Use the marina CLI."
                )
            }
        }

        // Defeats DNS rebinding: a page served from an attacker domain that
        // re-resolves to 127.0.0.1 still names that domain here.
        guard let host = request.headers["host"]?.lowercased(), allowedHosts.contains(host) else {
            return Rejection(status: 403, message: "Unexpected Host header for a loopback API")
        }

        // A cross-origin JSON body needs a CORS preflight, and this server
        // answers no preflight, so requiring JSON removes the no-preflight path
        // that a text/plain body would otherwise take.
        if !request.body.isEmpty {
            let contentType = request.headers["content-type"]?.lowercased() ?? ""
            guard contentType.hasPrefix("application/json") else {
                return Rejection(status: 415, message: "Request bodies must be application/json")
            }
        }

        if !Self.tokenFreePaths.contains(request.path) {
            guard let presented = request.bearerToken,
                  ControlToken.matches(presented, token) else {
                return Rejection(
                    status: 401,
                    message: "\(request.path) needs the API token from ~/.config/marina/token"
                )
            }
        }

        return nil
    }
}
