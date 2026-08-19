import Foundation

public enum MarinaClientError: LocalizedError {
    case appNotRunning
    case transport(String)
    case api(String)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .appNotRunning:
            return "Marina is not running and could not be launched. Open Marina.app, then retry."
        case .transport(let m): return "Cannot reach Marina: \(m)"
        case .api(let m): return m
        case .badResponse: return "Marina returned a response that could not be parsed."
        }
    }
}

/// Synchronous client for the app's local control API. Used by the CLI, which is
/// short-lived and has no run loop of its own.
public final class MarinaClient {
    private let port: Int
    private let session: URLSession

    public init(port: Int? = nil) {
        if let port {
            self.port = port
        } else {
            // The API port lives in the config, so a hand-edited port still works.
            self.port = ConfigStore.read(from: MarinaPaths.configFile)?.apiPort ?? MarinaConfig.defaultAPIPort
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        self.session = URLSession(configuration: cfg)
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    public func isReachable(timeout: TimeInterval = 1.0) -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("ping"))
        request.timeoutInterval = timeout
        var reachable = false
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 { reachable = true }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 0.5)
        return reachable
    }

    /// Launches Marina.app and waits for its API to answer.
    @discardableResult
    public func launchAppIfNeeded(timeout: TimeInterval = 20) -> Bool {
        if isReachable() { return true }
        let candidates = [
            "/Applications/Marina.app",
            NSString(string: "~/Applications/Marina.app").expandingTildeInPath,
        ]
        guard let appPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return false
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-g", appPath]
        try? proc.run()
        proc.waitUntilExit()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isReachable(timeout: 0.6) { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    public func request<Body: Codable, Response: Codable>(
        _ method: String,
        _ path: String,
        body: Body?,
        as: Response.Type,
        autoLaunch: Bool = true
    ) throws -> Response {
        if autoLaunch, !isReachable() {
            guard launchAppIfNeeded() else { throw MarinaClientError.appNotRunning }
        }

        // Built by hand: appendingPathComponent would escape the "?" of a query.
        guard let url = URL(string: baseURL.absoluteString + "/" + path) else {
            throw MarinaClientError.transport("bad path '\(path)'")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.httpBody = try MarinaAPI.encoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // Read after the app has had a chance to launch: it writes the token on
        // its first start, so a very first CLI call would otherwise find nothing.
        if let token = ControlToken.current() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var result: Data?
        var transportError: Error?
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, _, error in
            result = data
            transportError = error
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)

        if let transportError { throw MarinaClientError.transport(transportError.localizedDescription) }
        guard let result else { throw MarinaClientError.transport("no response") }

        guard let envelope = try? MarinaAPI.decoder().decode(MarinaAPI.Envelope<Response>.self, from: result) else {
            throw MarinaClientError.badResponse
        }
        guard envelope.ok, let data = envelope.data else {
            throw MarinaClientError.api(envelope.error ?? "unknown error")
        }
        return data
    }

    public func get<Response: Codable>(_ path: String, as type: Response.Type) throws -> Response {
        try request("GET", path, body: Optional<MarinaAPI.Empty>.none, as: type)
    }

    public func post<Body: Codable, Response: Codable>(_ path: String, _ body: Body, as type: Response.Type) throws -> Response {
        try request("POST", path, body: body, as: type)
    }
}
