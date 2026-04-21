import XCTest
@testable import Shipyard

final class HTTPRequestParserTests: XCTestCase {

    private func request(_ raw: String) -> Data {
        Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    func test_parsesMinimalPOST() {
        let raw = """
        POST /webhook HTTP/1.1
        Host: localhost:8080
        Content-Type: application/json
        Content-Length: 14
        X-GitHub-Event: ping
        X-Hub-Signature-256: sha256=abc

        {"hello":"hi"}
        """
        let parsed = HTTPRequestParser.tryParse(request(raw))
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.method, "POST")
        XCTAssertEqual(parsed?.path, "/webhook")
        XCTAssertEqual(parsed?.body, Data("{\"hello\":\"hi\"}".utf8))
        XCTAssertEqual(parsed?.headers["x-github-event"], "ping")
        XCTAssertEqual(parsed?.headers["x-hub-signature-256"], "sha256=abc")
    }

    func test_returnsNilWhenBodyIncomplete() {
        // Content-Length is 200 but the body we provide is 5 bytes —
        // parser should return nil so the caller keeps reading.
        let raw = """
        POST /webhook HTTP/1.1
        Content-Length: 200

        small
        """
        XCTAssertNil(HTTPRequestParser.tryParse(request(raw)))
    }

    func test_returnsNilWhenHeadersIncomplete() {
        let raw = "POST /webhook HTTP/1.1\r\nHost: x\r\n"   // no CRLF CRLF
        XCTAssertNil(HTTPRequestParser.tryParse(Data(raw.utf8)))
    }

    func test_headersAreLowercased() {
        let raw = """
        POST /webhook HTTP/1.1
        HOST: X
        Content-Length: 0


        """
        let parsed = HTTPRequestParser.tryParse(request(raw))
        XCTAssertEqual(parsed?.headers["host"], "X")
    }

    func test_pathParsesWithoutQueryStringHandling() {
        let raw = """
        POST /webhook?foo=bar HTTP/1.1
        Content-Length: 0


        """
        let parsed = HTTPRequestParser.tryParse(request(raw))
        // We don't trim query strings — route check keys off exact match,
        // so "/webhook?foo=bar" would 404, which is fine — webhook callers
        // never include a query.
        XCTAssertEqual(parsed?.path, "/webhook?foo=bar")
    }
}
