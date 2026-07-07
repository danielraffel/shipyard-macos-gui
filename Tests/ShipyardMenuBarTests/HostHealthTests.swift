import XCTest
@testable import Shipyard

final class HostHealthTests: XCTestCase {
    // MARK: - Pressure classification (kernel level → case)

    func testClassifyPressureLevels() {
        XCTAssertEqual(MemoryPressure.classify(level: 1), .normal)
        XCTAssertEqual(MemoryPressure.classify(level: 2), .warning)
        XCTAssertEqual(MemoryPressure.classify(level: 4), .critical)
        // Anything the kernel doesn't report as a known level (incl. nil) is
        // unknown — we must NOT fabricate "normal" when we don't actually know.
        XCTAssertEqual(MemoryPressure.classify(level: 0), .unknown)
        XCTAssertEqual(MemoryPressure.classify(level: 3), .unknown)
        XCTAssertEqual(MemoryPressure.classify(level: nil), .unknown)
    }

    // MARK: - Available-memory arithmetic (pure)

    func testAvailableBytesIsFreePlusInactiveTimesPageSize() {
        // 100 free + 50 inactive pages @ 16 KB = 150 * 16384.
        let sample = VMSample(freePages: 100, inactivePages: 50,
                              pageSize: 16_384, totalBytes: 8_589_934_592)
        XCTAssertEqual(HostHealth.availableBytes(sample), 150 * 16_384)
    }

    func testAvailableBytesZeroPages() {
        let sample = VMSample(freePages: 0, inactivePages: 0,
                              pageSize: 4_096, totalBytes: 0)
        XCTAssertEqual(HostHealth.availableBytes(sample), 0)
    }

    // MARK: - Byte formatting (deterministic)

    func testFormatBytesGBAndMB() {
        XCTAssertEqual(HostHealth.formatBytes(2 * 1_073_741_824), "2.0 GB")
        // 1.5 GiB → one decimal.
        XCTAssertEqual(HostHealth.formatBytes(1_610_612_736), "1.5 GB")
        // Below 1 GiB drops to whole MB.
        XCTAssertEqual(HostHealth.formatBytes(512 * 1_048_576), "512 MB")
        XCTAssertEqual(HostHealth.formatBytes(0), "0 MB")
    }

    // MARK: - read() composes injected providers, degrades gracefully

    func testReadComposesInjectedProviders() {
        let sample = VMSample(freePages: 200, inactivePages: 100,
                              pageSize: 4_096, totalBytes: 17_179_869_184)
        let health = HostHealthProbe.read(
            load: { 3.5 },
            pressure: { 2 },
            memory: { sample })
        XCTAssertEqual(health.loadAverage1m, 3.5, accuracy: 0.0001)
        XCTAssertEqual(health.pressure, .warning)
        XCTAssertEqual(health.freeBytes, 300 * 4_096)
        XCTAssertEqual(health.totalBytes, 17_179_869_184)
        XCTAssertEqual(health.loadSummary, "3.50")
    }

    func testReadDegradesWhenProvidersReturnNil() {
        // A partial kernel hiccup must still paint a usable panel: load → 0,
        // pressure → unknown, memory → zeroes (never a crash, never bogus data).
        let health = HostHealthProbe.read(
            load: { nil }, pressure: { nil }, memory: { nil })
        XCTAssertEqual(health.loadAverage1m, 0)
        XCTAssertEqual(health.pressure, .unknown)
        XCTAssertEqual(health.freeBytes, 0)
        XCTAssertEqual(health.totalBytes, 0)
        XCTAssertEqual(health.freeFraction, 0)   // no divide-by-zero → NaN
    }

    func testFreeFractionClampsAndGuardsZeroTotal() {
        let half = HostHealth(loadAverage1m: 0, pressure: .normal,
                              freeBytes: 4, totalBytes: 8)
        XCTAssertEqual(half.freeFraction, 0.5, accuracy: 0.0001)
        // free > total (transient page-count skew) clamps to 1, never > 1.
        let over = HostHealth(loadAverage1m: 0, pressure: .normal,
                              freeBytes: 10, totalBytes: 8)
        XCTAssertEqual(over.freeFraction, 1.0, accuracy: 0.0001)
    }

    // MARK: - Live read is well-formed on the real host (no mutation)

    func testLiveReadProducesSaneValues() {
        // Read-only smoke: the live providers must return plausible, non-crashing
        // values on the CI host. We assert shape, not exact numbers.
        let health = HostHealthProbe.read()
        XCTAssertGreaterThanOrEqual(health.loadAverage1m, 0)
        XCTAssertGreaterThan(health.totalBytes, 0)          // every Mac has RAM
        XCTAssertLessThanOrEqual(health.freeBytes, health.totalBytes)
    }
}
