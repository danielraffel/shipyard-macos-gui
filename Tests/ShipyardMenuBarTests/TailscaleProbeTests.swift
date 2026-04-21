import XCTest
@testable import Shipyard

final class TailscaleProbeTests: XCTestCase {

    func test_decode_readyHappyPath() {
        let json = """
        {
          "BackendState": "Running",
          "Self": {
            "DNSName": "spacely.corvus-rufinus.ts.net.",
            "CapMap": {
              "https://tailscale.com/cap/funnel": ["ports:443"]
            }
          }
        }
        """.data(using: .utf8)!
        let status = TailscaleProbe.decode(json: json, binaryPath: "/usr/local/bin/tailscale")
        XCTAssertTrue(status.isReady)
        XCTAssertEqual(status.funnelURL?.absoluteString, "https://spacely.corvus-rufinus.ts.net")
    }

    func test_decode_backendNotRunning_isNotReady() {
        let json = """
        {
          "BackendState": "NeedsLogin",
          "Self": {
            "DNSName": "foo.ts.net",
            "CapMap": { "https://tailscale.com/cap/funnel": [] }
          }
        }
        """.data(using: .utf8)!
        let status = TailscaleProbe.decode(json: json, binaryPath: "/x")
        XCTAssertFalse(status.isReady)
        XCTAssertNil(status.funnelURL)
    }

    func test_decode_missingFunnelCap_isNotReady() {
        let json = """
        {
          "BackendState": "Running",
          "Self": {
            "DNSName": "foo.ts.net",
            "CapMap": { "https://tailscale.com/cap/other": [] }
          }
        }
        """.data(using: .utf8)!
        let status = TailscaleProbe.decode(json: json, binaryPath: "/x")
        XCTAssertFalse(status.isReady)
    }

    func test_decode_bareFunnelKeyAccepted() {
        let json = """
        {
          "BackendState": "Running",
          "Self": {
            "DNSName": "foo.ts.net",
            "CapMap": { "funnel": [] }
          }
        }
        """.data(using: .utf8)!
        let status = TailscaleProbe.decode(json: json, binaryPath: "/x")
        XCTAssertTrue(status.isReady)
    }

    func test_decode_trailingDotStrippedFromDNSName() {
        let json = """
        {
          "BackendState": "Running",
          "Self": {
            "DNSName": "foo.ts.net.",
            "CapMap": { "https://tailscale.com/cap/funnel": [] }
          }
        }
        """.data(using: .utf8)!
        let status = TailscaleProbe.decode(json: json, binaryPath: "/x")
        XCTAssertEqual(status.funnelURL?.absoluteString, "https://foo.ts.net")
    }

    func test_decode_malformedJSON_returnsNotReady() {
        let status = TailscaleProbe.decode(json: Data("not json".utf8), binaryPath: "/x")
        XCTAssertFalse(status.isReady)
        XCTAssertNil(status.funnelURL)
    }

    func test_decode_nilBinaryPath_isNotReady() {
        let json = """
        {
          "BackendState": "Running",
          "Self": {
            "DNSName": "foo.ts.net",
            "CapMap": { "https://tailscale.com/cap/funnel": [] }
          }
        }
        """.data(using: .utf8)!
        let status = TailscaleProbe.decode(json: json, binaryPath: nil)
        XCTAssertFalse(status.isReady)
    }
}
