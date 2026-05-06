import XCTest
@testable import Shipyard

final class ProcessEnvironmentTests: XCTestCase {
    func test_augmentedPathPrependsUserToolDirectories() {
        let path = ShipyardProcessEnvironment.augmentedPath(from: "/custom/bin:/usr/bin")
        let parts = path.split(separator: ":").map(String.init)

        XCTAssertEqual(parts.first, NSHomeDirectory() + "/.local/bin")
        XCTAssertTrue(parts.contains("/opt/homebrew/bin"))
        XCTAssertTrue(parts.contains("/usr/local/bin"))
        XCTAssertTrue(parts.contains("/Applications/Tailscale.app/Contents/MacOS"))
        XCTAssertTrue(parts.contains("/custom/bin"))
    }

    func test_augmentedPathDeduplicatesExistingEntries() {
        let path = ShipyardProcessEnvironment.augmentedPath(
            from: "/opt/homebrew/bin:/usr/bin:/opt/homebrew/bin"
        )
        let parts = path.split(separator: ":").map(String.init)

        XCTAssertEqual(parts.filter { $0 == "/opt/homebrew/bin" }.count, 1)
        XCTAssertEqual(parts.filter { $0 == "/usr/bin" }.count, 1)
    }

    func test_augmentedEnvironmentPreservesExtraValues() {
        let environment = ShipyardProcessEnvironment.augmented(
            from: ["PATH": "/usr/bin", "HOME": "/tmp/home"],
            extra: [
                "SHIPYARD_ENABLE_TUNNEL": "1",
                "SHIPYARD_RUST_ENABLE_TUNNEL": "1",
            ]
        )

        XCTAssertEqual(environment["HOME"], "/tmp/home")
        XCTAssertEqual(environment["SHIPYARD_ENABLE_TUNNEL"], "1")
        XCTAssertEqual(environment["SHIPYARD_RUST_ENABLE_TUNNEL"], "1")
        XCTAssertTrue(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    }
}
