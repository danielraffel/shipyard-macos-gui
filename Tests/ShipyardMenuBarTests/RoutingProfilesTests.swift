import XCTest
@testable import Shipyard

final class RoutingProfilesTests: XCTestCase {
    private let decoder = JSONDecoder()

    func testDecodesNewEnvelopeWithActiveSource() throws {
        let json = """
        {"command":"config.profiles",
         "profiles":[
           {"name":"local","active":false,"targets":["mac"],"description":"Just my Mac"},
           {"name":"cloud","active":true,"targets":["mac-cloud","ubuntu-cloud"],"description":"Everything on cloud"}],
         "active":"cloud","active_source":"local","active_path":"/r/.shipyard.local/config.toml",
         "local_overlay_source":"direct","local_overlay_path":"/r/.shipyard.local/config.toml",
         "tracked_config_path":"/r/.shipyard/config.toml"}
        """
        let snap = try decoder.decode(RoutingProfilesSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.active, "cloud")
        XCTAssertEqual(snap.activeSource, .local)
        XCTAssertTrue(snap.cliReportsActiveSource)
        XCTAssertEqual(snap.localOverlaySource, .direct)
        XCTAssertEqual(snap.profiles.count, 2)
        XCTAssertEqual(snap.profiles[0].displayLabel, "Just my Mac")
        XCTAssertEqual(snap.profiles[1].targets, ["mac-cloud", "ubuntu-cloud"])
    }

    func testDecodesOldEnvelopeWithoutActiveSource() throws {
        let json = """
        {"command":"config.profiles",
         "profiles":[{"name":"local","active":true,"targets":["mac"]}],
         "active":"local"}
        """
        let snap = try decoder.decode(RoutingProfilesSnapshot.self, from: Data(json.utf8))
        // Missing active_source → .unknown, which gates writes off.
        XCTAssertEqual(snap.activeSource, .unknown)
        XCTAssertFalse(snap.cliReportsActiveSource)
        // Missing description → canonical fallback label.
        XCTAssertEqual(snap.profiles[0].displayLabel, "Just my Mac")
    }

    func testNoProfiles() throws {
        let json = #"{"command":"config.profiles","profiles":[],"active":null,"active_source":"none"}"#
        let snap = try decoder.decode(RoutingProfilesSnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(snap.profiles.isEmpty)
        XCTAssertNil(snap.active)
        XCTAssertEqual(snap.activeSource, RoutingActiveSource.none)
    }

    func testUnknownProfileNameFallsBackToName() throws {
        let json = #"{"command":"config.profiles","profiles":[{"name":"weird","active":false,"targets":[]}],"active":null}"#
        let snap = try decoder.decode(RoutingProfilesSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snap.profiles[0].displayLabel, "weird")
    }

    func testRoutingRepositoryStableIDs() {
        let rooted = RoutingRepository.rooted(repo: "o/r", repoRoot: "/code/r")
        XCTAssertEqual(rooted.id, "/code/r")
        XCTAssertEqual(rooted.source, .shipState)

        let noRoot = RoutingRepository.noRoot(repo: "o/r", override: nil)
        XCTAssertEqual(noRoot.id, "noroot:o/r")
        XCTAssertNil(noRoot.repoRoot)

        // id stays stable after an override is applied (proposal §3b).
        let overridden = RoutingRepository.noRoot(repo: "o/r", override: "/code/r2")
        XCTAssertEqual(overridden.id, "noroot:o/r")
        XCTAssertEqual(overridden.repoRoot, "/code/r2")
        XCTAssertEqual(overridden.source, .userOverride)
    }
}
