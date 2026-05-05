import XCTest
@testable import Shipyard

final class NamespaceActivityTests: XCTestCase {
    func test_decodeNSCListJSON() {
        let snapshot = NamespaceActivityPoller.decode(rawOutput: """
        [
          {
            "cluster_id": "i3446qovgf5pg",
            "created_at": "2026-05-05T17:30:19.442759636Z",
            "ingress_domain": "iad4.nscluster.cloud",
            "labels": {
              "nsc.purpose": "github-runner",
              "nsc.runner-profile-tag": "namespace-profile-generouscorp-windows",
              "nsc.runner-repo": "danielraffel/pulp"
            },
            "shape": {
              "virtual_cpu": 4,
              "memory_megabytes": 8192,
              "machine_arch": "amd64",
              "os": "windows"
            }
          }
        ]
        """)

        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.instances.count, 1)
        XCTAssertEqual(snapshot.instances.first?.id, "i3446qovgf5pg")
        XCTAssertEqual(snapshot.instances.first?.repo, "danielraffel/pulp")
        XCTAssertEqual(snapshot.instances.first?.platformKey, "windows")
        XCTAssertEqual(snapshot.instances.first?.shapeLabel, "win/amd64 4x8")
        XCTAssertEqual(snapshot.instances.first?.platformLabel, "win/amd64")
        XCTAssertEqual(snapshot.instances.first?.sizeLabel, "4x8")
        XCTAssertEqual(snapshot.instances.first?.title, "GitHub runner")
    }

    func test_decodeToleratesUpdateNoticeBeforeJSON() {
        let snapshot = NamespaceActivityPoller.decode(rawOutput: """
        info: A new version of nsc is available.
        [
          {
            "cluster_id": "runner-1",
            "created_at": "2026-05-05T17:30:19Z",
            "labels": {},
            "shape": {
              "virtual_cpu": 6,
              "memory_megabytes": 14336,
              "machine_arch": "arm64",
              "os": "macos"
            }
          }
        ]
        """)

        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.instances.first?.id, "runner-1")
        XCTAssertEqual(snapshot.instances.first?.platformKey, "macos")
        XCTAssertEqual(snapshot.instances.first?.shapeLabel, "mac/silicon 6x14")
        XCTAssertEqual(snapshot.instances.first?.platformLabel, "mac/silicon")
        XCTAssertEqual(snapshot.instances.first?.sizeLabel, "6x14")
    }

    func test_decodeNSCDescribeJSON() {
        let snapshot = NamespaceActivityPoller.decodeDetail(rawOutput: """
        [
          {
            "resource": "nsc/containers",
            "per_resource": {
              "q3339thciouks": {
                "namespace": "default",
                "name": "github-runner",
                "uid": "q3339thciouks",
                "creation_time": "2026-05-05T18:11:29.395569235Z",
                "updated_time": "2026-05-05T18:11:29.395569235Z",
                "container": [
                  {
                    "id": "d6d1f743721a496264aefa1de63ce05d2d020e72311153c2306b12b73077bbb9",
                    "name": "github-runner",
                    "started_at": "2026-05-05T18:11:29.395569235Z",
                    "ready": true,
                    "status": "running"
                  }
                ]
              }
            }
          }
        ]
        """)

        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.detail?.containers.count, 1)
        XCTAssertEqual(snapshot.detail?.containers.first?.name, "github-runner")
        XCTAssertEqual(snapshot.detail?.containers.first?.statusLabel, "running, ready")
        XCTAssertEqual(snapshot.detail?.statusSummary, "github-runner: running, ready")
    }

    func test_decodeNSCDescribeWithoutJSONIsEmptyDetail() {
        let snapshot = NamespaceActivityPoller.decodeDetail(rawOutput: """
        Failed: runner-1: does not exist.
        """)

        XCTAssertNil(snapshot.error)
        XCTAssertEqual(snapshot.detail?.containers, [])
    }
}
