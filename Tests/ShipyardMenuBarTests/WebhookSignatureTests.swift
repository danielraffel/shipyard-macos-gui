import XCTest
@testable import Shipyard

final class WebhookSignatureTests: XCTestCase {

    func test_matchesGitHubReferenceVector() {
        // Matches the example from GitHub's webhooks docs:
        // https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries
        let body = Data("Hello, World!".utf8)
        let secret = "It's a Secret to Everybody"
        let expected = "757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"
        let got = WebhookSignature.hmacSHA256Hex(body: body, secret: secret)
        XCTAssertEqual(got, expected)
    }

    func test_acceptsSha256PrefixedHeader() {
        let body = Data("payload".utf8)
        let secret = "shh"
        let mac = WebhookSignature.hmacSHA256Hex(body: body, secret: secret)
        XCTAssertTrue(WebhookSignature.isValid(
            body: body, secret: secret, header: "sha256=\(mac)"
        ))
    }

    func test_acceptsBareHexHeader() {
        let body = Data("payload".utf8)
        let secret = "shh"
        let mac = WebhookSignature.hmacSHA256Hex(body: body, secret: secret)
        XCTAssertTrue(WebhookSignature.isValid(
            body: body, secret: secret, header: mac
        ))
    }

    func test_rejectsBodyTamper() {
        let body = Data("payload".utf8)
        let secret = "shh"
        let mac = WebhookSignature.hmacSHA256Hex(body: body, secret: secret)
        XCTAssertFalse(WebhookSignature.isValid(
            body: Data("payloa!".utf8),  // tampered
            secret: secret,
            header: "sha256=\(mac)"
        ))
    }

    func test_rejectsSecretMismatch() {
        let body = Data("payload".utf8)
        let mac = WebhookSignature.hmacSHA256Hex(body: body, secret: "shh")
        XCTAssertFalse(WebhookSignature.isValid(
            body: body, secret: "wrong", header: "sha256=\(mac)"
        ))
    }

    func test_rejectsMissingHeader() {
        let body = Data("payload".utf8)
        XCTAssertFalse(WebhookSignature.isValid(
            body: body, secret: "shh", header: nil
        ))
        XCTAssertFalse(WebhookSignature.isValid(
            body: body, secret: "shh", header: ""
        ))
    }

    func test_generateSecret_isDistinctAndBase64() {
        let a = WebhookSignature.generateSecret()
        let b = WebhookSignature.generateSecret()
        XCTAssertNotEqual(a, b)
        XCTAssertNotNil(Data(base64Encoded: a))
    }

    func test_constantTimeEquals_behavesLikeEquality() {
        XCTAssertTrue(WebhookSignature.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(WebhookSignature.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(WebhookSignature.constantTimeEquals("abc", "abcd"))
        XCTAssertTrue(WebhookSignature.constantTimeEquals("", ""))
    }
}
