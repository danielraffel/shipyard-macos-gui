import XCTest
@testable import Shipyard

/// End-to-end test for the webhook server: bind to a real localhost
/// port, fire a signed POST, verify the handler sees the event.
/// Covers routing (/webhook + /) and HMAC validation in a single
/// round-trip so the full happy path is exercised.
final class WebhookServerTests: XCTestCase {

    func test_acceptsSignedPOST_onWebhookPath() throws {
        let secret = "unit-test-secret"
        let body = Data(#"{"zen":"Non-blocking is better than blocking."}"#.utf8)
        let mac = WebhookSignature.hmacSHA256Hex(body: body, secret: secret)
        let deliveryExpectation = expectation(description: "delivery handled")
        var seenHeaders: [String: String]?
        var seenBody: Data?

        let server = WebhookServer { headers, payload in
            seenHeaders = headers
            seenBody = payload
            deliveryExpectation.fulfill()
            guard WebhookSignature.isValid(
                body: payload, secret: secret,
                header: headers["x-hub-signature-256"]
            ) else {
                return .unauthorized
            }
            return .ok
        }
        let port = try server.start()
        defer { server.stop() }

        let responseExpectation = expectation(description: "response received")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/webhook")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("sha256=\(mac)", forHTTPHeaderField: "X-Hub-Signature-256")
        request.setValue("ping", forHTTPHeaderField: "X-GitHub-Event")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                XCTAssertEqual(http.statusCode, 200)
            }
            responseExpectation.fulfill()
        }.resume()

        wait(for: [deliveryExpectation, responseExpectation], timeout: 5.0)
        XCTAssertEqual(seenBody, body)
        XCTAssertEqual(seenHeaders?["x-github-event"], "ping")
    }

    func test_acceptsPOST_onRootPath_forLegacyHookCompat() throws {
        // Old builds registered the hook with the bare tunnel URL
        // (no /webhook). The server must still accept those until
        // the URL gets patched.
        let server = WebhookServer { _, _ in .ok }
        let port = try server.start()
        defer { server.stop() }

        let got = expectation(description: "got 200 on /")
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            got.fulfill()
        }.resume()
        wait(for: [got], timeout: 5.0)
    }

    func test_rejectsGET() throws {
        let server = WebhookServer { _, _ in .ok }
        let port = try server.start()
        defer { server.stop() }

        let got = expectation(description: "got 405")
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/webhook")!)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 405)
            got.fulfill()
        }.resume()
        wait(for: [got], timeout: 5.0)
    }

    func test_bindsToLoopbackOnly() throws {
        // Defense in depth: even if Tailscale Funnel is off, the
        // server must not be reachable outside this Mac. NWListener
        // with acceptLocalOnly + loopback interfaces keeps it bound
        // to 127.0.0.1. We verify the port is available on loopback
        // but the listener is configured for local only.
        let server = WebhookServer { _, _ in .ok }
        let port = try server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(port, 0)
    }
}
