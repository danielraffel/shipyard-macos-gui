import XCTest
@testable import Shipyard

final class FleetShipStateTests: XCTestCase {
    private func tmp(_ contents: String) -> String {
        let p = NSTemporaryDirectory() + "fleet-\(UUID().uuidString).json"
        try? contents.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    func testHostsParsesDedupsAndDropsBlanks() {
        let p = tmp("""
        [{"name":"M3","ssh":"macstudio"},
         {"name":"M1","ssh":"m1"},
         {"name":"dup","ssh":"macstudio"},
         {"name":"","ssh":"x"},
         {"name":"y","ssh":""}]
        """)
        defer { try? FileManager.default.removeItem(atPath: p) }
        let hosts = FleetShipState.hosts(path: p)
        // dup ssh dropped, blanks dropped, order preserved
        XCTAssertEqual(hosts.map(\.ssh), ["macstudio", "m1"])
        XCTAssertEqual(hosts.map(\.name), ["M3", "M1"])
    }

    func testHostsMissingOrGarbageFileIsEmpty() {
        XCTAssertEqual(FleetShipState.hosts(path: "/no/such/fleet.json").count, 0)
        let p = tmp("not json")
        defer { try? FileManager.default.removeItem(atPath: p) }
        XCTAssertEqual(FleetShipState.hosts(path: p).count, 0)
    }

    func testDecodeAndMapShipStateToFleetPRs() {
        let json = """
        {"command":"ship-state:list","schema_version":1,"states":[
          {"pr":4172,"repo":"danielraffel/pulp","branch":"fix/x","pr_title":"Fix X","pr_url":"https://github.com/danielraffel/pulp/pull/4172","head_sha":"abc"},
          {"pr":4167,"repo":"danielraffel/pulp","commit_subject":"Feat Y"},
          {"pr":9,"branch":"no-repo"}
        ]}
        """
        let entries = ShipStateListEntry.decode(fromJSON: json)
        XCTAssertEqual(entries?.count, 3)
        let prs = FleetShipState.map(entries ?? [], machine: "M3")
        // the no-repo entry is dropped
        XCTAssertEqual(prs.count, 2)
        XCTAssertEqual(prs[0].machine, "M3")
        XCTAssertEqual(prs[0].prNumber, 4172)
        XCTAssertEqual(prs[0].title, "Fix X")
        XCTAssertEqual(prs[0].prURL, "https://github.com/danielraffel/pulp/pull/4172")
        // title falls back to commit subject when pr_title absent
        XCTAssertEqual(prs[1].title, "Feat Y")
        // stable id = machine + repo + number
        XCTAssertEqual(prs[0].id, "M3\tdanielraffel/pulp\t4172")
    }

    func testDecodeBareArrayShape() {
        let arr = """
        [{"pr":1,"repo":"a/b","pr_title":"t"}]
        """
        let entries = ShipStateListEntry.decode(fromJSON: arr)
        XCTAssertEqual(entries?.count, 1)
        XCTAssertEqual(FleetShipState.map(entries ?? [], machine: "M1").first?.repo, "a/b")
    }
}
