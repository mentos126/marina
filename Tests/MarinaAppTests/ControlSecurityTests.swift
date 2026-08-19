import Foundation
import MarinaCore
@testable import MarinaApp
import XCTest

/// The control API can read every server environment and start commands, so the
/// interesting cases here are the ones a web page can produce.
final class ControlSecurityTests: XCTestCase {
    private let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    private var sut: ControlRequestGuard { ControlRequestGuard(port: 7737, token: token) }

    // MARK: - Parsing

    func testParsesHeadersAndBearerToken() throws {
        let request = try make(headers: [
            "Host": "127.0.0.1:7737",
            "Authorization": "Bearer \(token)",
            "X-Repeated": "first",
        ])

        XCTAssertEqual(request.headers["host"], "127.0.0.1:7737")
        XCTAssertEqual(request.bearerToken, token)
        XCTAssertEqual(request.headers["x-repeated"], "first")
    }

    func testIgnoresARepeatedHeaderAfterTheFirst() throws {
        var text = "GET /status HTTP/1.1\r\n"
        text += "Host: 127.0.0.1:7737\r\n"
        text += "Host: evil.tld\r\n\r\n"
        let request = try XCTUnwrap(HTTPRequest(Data(text.utf8)))

        XCTAssertEqual(request.headers["host"], "127.0.0.1:7737")
    }

    func testDeclaredContentLengthIsReadableBeforeTheBodyArrives() {
        var text = "POST /temporary/run HTTP/1.1\r\n"
        text += "Host: 127.0.0.1:7737\r\n"
        text += "Content-Length: 9999999\r\n\r\n"

        XCTAssertNil(HTTPRequest(Data(text.utf8)), "an incomplete body must not route")
        XCTAssertEqual(HTTPRequest.declaredContentLength(in: Data(text.utf8)), 9_999_999)
    }

    // MARK: - Browser-originated requests

    func testRejectsCrossOriginPost() throws {
        // The CSRF shape: a page posting a command to the fixed local port.
        let request = try make(
            method: "POST",
            path: "/temporary/run",
            headers: [
                "Host": "127.0.0.1:7737",
                "Origin": "https://evil.tld",
                "Content-Type": "application/json",
            ],
            body: #"{"name":"x","command":"curl evil.tld","directory":"~"}"#
        )

        XCTAssertEqual(sut.rejection(for: request)?.status, 403)
    }

    func testRejectsFetchMetadataHeadersEvenWithoutOrigin() throws {
        for header in ["Sec-Fetch-Site", "Sec-Fetch-Mode", "Sec-Fetch-Dest", "Cookie"] {
            let request = try make(headers: ["Host": "127.0.0.1:7737", header: "cross-site"])
            XCTAssertEqual(sut.rejection(for: request)?.status, 403, "\(header) should be refused")
        }
    }

    func testRejectsARebindingHostWhileAcceptingLoopbackNames() throws {
        let rebound = try make(headers: ["Host": "evil.tld:7737"])
        XCTAssertEqual(sut.rejection(for: rebound)?.status, 403)

        let missing = try make(headers: [:])
        XCTAssertEqual(sut.rejection(for: missing)?.status, 403)

        let wrongPort = try make(headers: ["Host": "127.0.0.1:9999"])
        XCTAssertEqual(sut.rejection(for: wrongPort)?.status, 403)

        for host in ["127.0.0.1:7737", "localhost:7737", "[::1]:7737", "LOCALHOST:7737"] {
            XCTAssertNil(sut.rejection(for: try make(headers: ["Host": host])), "\(host) should pass")
        }
    }

    func testRejectsANonJSONBodyBecauseItSkipsThePreflight() throws {
        // text/plain is a CORS-safelisted type, so a browser sends it without a
        // preflight. Requiring JSON removes that path.
        let request = try make(
            method: "POST",
            path: "/stop",
            headers: ["Host": "127.0.0.1:7737", "Content-Type": "text/plain"],
            body: #"{"server":"web"}"#
        )

        XCTAssertEqual(sut.rejection(for: request)?.status, 415)
    }

    // MARK: - Token

    func testSecretBearingRoutesRequireTheToken() throws {
        for path in ["/config", "/logs", "/temporary/run", "/servers/add", "/ports/kill", "/quit"] {
            let anonymous = try make(path: path, headers: ["Host": "127.0.0.1:7737"])
            XCTAssertEqual(sut.rejection(for: anonymous)?.status, 401, "\(path) must need the token")

            let authorized = try make(
                path: path,
                headers: ["Host": "127.0.0.1:7737", "Authorization": "Bearer \(token)"]
            )
            XCTAssertNil(sut.rejection(for: authorized), "\(path) should accept the token")
        }
    }

    func testWrongTokenIsRefused() throws {
        for value in ["Bearer wrong", "Bearer ", "Basic \(token)", token] {
            let request = try make(
                path: "/config",
                headers: ["Host": "127.0.0.1:7737", "Authorization": value]
            )
            XCTAssertEqual(sut.rejection(for: request)?.status, 401, "'\(value)' must be refused")
        }
    }

    func testCompanionRoutesStayReachableWithoutTheToken() throws {
        // The App Store companion is sandboxed and cannot read the token file.
        for path in ControlRequestGuard.tokenFreePaths {
            let request = try make(path: path, headers: ["Host": "127.0.0.1:7737"])
            XCTAssertNil(sut.rejection(for: request), "\(path) should stay reachable")
        }
        XCTAssertFalse(ControlRequestGuard.tokenFreePaths.contains("/config"))
        XCTAssertFalse(ControlRequestGuard.tokenFreePaths.contains("/logs"))
    }

    // MARK: - Token file

    func testTokenIsHexAndStoredOwnerOnly() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("token")
        defer { try? FileManager.default.removeItem(at: directory) }

        let created = ControlToken.loadOrCreate(at: url)

        XCTAssertEqual(created.count, 64)
        XCTAssertTrue(created.allSatisfy { $0.isHexDigit })
        XCTAssertEqual(ControlToken.loadOrCreate(at: url), created, "must be stable across launches")
        XCTAssertEqual(ControlToken.read(from: url), created)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        let directoryMode = try FileManager.default
            .attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(directoryMode, 0o700)
    }

    func testTokenComparisonRejectsPrefixesAndEmptyValues() {
        XCTAssertTrue(ControlToken.matches(token, token))
        XCTAssertFalse(ControlToken.matches(String(token.dropLast()), token))
        XCTAssertFalse(ControlToken.matches(token + "0", token))
        XCTAssertFalse(ControlToken.matches("", token))
    }

    // MARK: - Helpers

    private func make(
        method: String = "GET",
        path: String = "/status",
        headers: [String: String],
        body: String = ""
    ) throws -> HTTPRequest {
        var all = headers
        if !body.isEmpty, all["Content-Type"] == nil { all["Content-Type"] = "application/json" }
        var text = "\(method) \(path) HTTP/1.1\r\n"
        for (name, value) in all { text += "\(name): \(value)\r\n" }
        if !body.isEmpty { text += "Content-Length: \(body.utf8.count)\r\n" }
        text += "\r\n\(body)"
        return try XCTUnwrap(HTTPRequest(Data(text.utf8)))
    }
}
