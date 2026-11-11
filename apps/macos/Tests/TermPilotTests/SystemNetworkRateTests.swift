@testable import TermPilotApp
import XCTest

final class SystemNetworkRateTests: XCTestCase {
    func testRatesUseCounterDeltaAndActualElapsedTime() throws {
        let rates = try XCTUnwrap(
            SystemNetworkRateCalculator.rates(
                current: SystemNetworkByteCounters(
                    rxBytes: 1_500,
                    txBytes: 3_250
                ),
                previous: SystemNetworkByteCounters(
                    rxBytes: 1_000,
                    txBytes: 2_000
                ),
                elapsed: 2.5
            )
        )

        XCTAssertEqual(rates.rxBps, 200, accuracy: 0.001)
        XCTAssertEqual(rates.txBps, 500, accuracy: 0.001)
    }

    func testRatesPreserveNonzeroTrafficBelowOneBytePerSecond() throws {
        let rates = try XCTUnwrap(
            SystemNetworkRateCalculator.rates(
                current: SystemNetworkByteCounters(
                    rxBytes: 101,
                    txBytes: 200
                ),
                previous: SystemNetworkByteCounters(
                    rxBytes: 100,
                    txBytes: 200
                ),
                elapsed: 2
            )
        )

        XCTAssertEqual(rates.rxBps, 0.5, accuracy: 0.001)
        XCTAssertEqual(rates.txBps, 0, accuracy: 0.001)
    }

    func testRatesRejectCounterReset() {
        let rates = SystemNetworkRateCalculator.rates(
            current: SystemNetworkByteCounters(
                rxBytes: 100,
                txBytes: 300
            ),
            previous: SystemNetworkByteCounters(
                rxBytes: 200,
                txBytes: 250
            ),
            elapsed: 1
        )

        XCTAssertNil(rates)
    }

    func testRatesRejectNonpositiveElapsedTime() {
        let counters = SystemNetworkByteCounters(
            rxBytes: 100,
            txBytes: 200
        )

        XCTAssertNil(
            SystemNetworkRateCalculator.rates(
                current: counters,
                previous: counters,
                elapsed: 0
            )
        )
    }
}
