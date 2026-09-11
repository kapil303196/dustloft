import XCTest
import Foundation
@testable import Dustloft

/// Covers the reporting rules, which are pure on purpose.
///
/// Two kinds of mistake matter here and neither is visible by eye: sending more
/// often than promised, and sending more than was promised. The throttle and
/// the literal payload are therefore both pinned by tests.
final class MetricsTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: When to report

    func test_reportsOnceWhenNothingHasEverBeenSent() {
        XCTAssertTrue(MetricsRules.shouldReport(
            now: epoch, lastReport: nil, reportedTotal: 0, currentTotal: 0))
    }

    func test_doesNotReportAgainImmediatelyAfterCleaning() {
        // Two cleans a few seconds apart must not become two reports.
        XCTAssertFalse(MetricsRules.shouldReport(
            now: epoch.addingTimeInterval(5),
            lastReport: epoch, reportedTotal: 100, currentTotal: 900))
    }

    func test_reportsOnceTheTotalMovesAndTheFloorHasPassed() {
        XCTAssertTrue(MetricsRules.shouldReport(
            now: epoch.addingTimeInterval(120),
            lastReport: epoch, reportedTotal: 100, currentTotal: 900))
    }

    func test_staysSilentWhenNothingChanged() {
        XCTAssertFalse(MetricsRules.shouldReport(
            now: epoch.addingTimeInterval(3600),
            lastReport: epoch, reportedTotal: 900, currentTotal: 900))
    }

    /// Without this an install that updates but never cleans again would keep
    /// being counted against the version it was first seen on.
    func test_heartbeatReportsEvenWithNoChange() {
        XCTAssertTrue(MetricsRules.shouldReport(
            now: epoch.addingTimeInterval(24 * 60 * 60),
            lastReport: epoch, reportedTotal: 900, currentTotal: 900))
    }

    /// A clock corrected backwards by months would otherwise freeze reporting
    /// until real time caught up with the stale stamp.
    func test_clockMovingBackwardsDoesNotWedgeIt() {
        XCTAssertTrue(MetricsRules.shouldReport(
            now: epoch.addingTimeInterval(-99_999),
            lastReport: epoch, reportedTotal: 900, currentTotal: 900))
    }

    // MARK: Accumulating

    func test_accumulateAddsAndIgnoresNonPositive() {
        XCTAssertEqual(MetricsRules.accumulate(10, 5), 15)
        XCTAssertEqual(MetricsRules.accumulate(10, 0), 10)
        XCTAssertEqual(MetricsRules.accumulate(10, -5), 10)
    }

    /// The ceiling is shared with the server, which clamps to the same value.
    /// If one of them ever moves, `MAX_CLEANED` in site/api/ping.mjs moves too.
    func test_accumulateClampsRatherThanWrapping() {
        XCTAssertEqual(MetricsRules.maxCleaned, 1_000_000_000_000_000)
        XCTAssertEqual(MetricsRules.accumulate(MetricsRules.maxCleaned, 1),
                       MetricsRules.maxCleaned)
        XCTAssertEqual(MetricsRules.accumulate(Int64.max - 1, 1_000),
                       MetricsRules.maxCleaned)
    }

    // MARK: Version

    func test_versionAcceptsWhatTheServerAccepts() {
        XCTAssertEqual(MetricsRules.sanitizedVersion("1.0.26"), "1.0.26")
        XCTAssertEqual(MetricsRules.sanitizedVersion("1"), "1")
        XCTAssertEqual(MetricsRules.sanitizedVersion("1.2.3.4"), "1.2.3.4")
    }

    func test_versionDropsAnythingElseRatherThanBeingRefused() {
        XCTAssertEqual(MetricsRules.sanitizedVersion(""), "")
        XCTAssertEqual(MetricsRules.sanitizedVersion("1.0.26-beta"), "")
        XCTAssertEqual(MetricsRules.sanitizedVersion("v1.0.26"), "")
        XCTAssertEqual(MetricsRules.sanitizedVersion("1.2.3.4.5"), "")
        XCTAssertEqual(MetricsRules.sanitizedVersion("1..2"), "")
        XCTAssertEqual(MetricsRules.sanitizedVersion("12345"), "")
        // Digits that are not ASCII would pass a naive isNumber check.
        XCTAssertEqual(MetricsRules.sanitizedVersion("١.٠"), "")
    }

    func test_identifierMustBeAUUID() {
        XCTAssertTrue(MetricsRules.isValidID("11111111-2222-4333-8444-555555555555"))
        XCTAssertFalse(MetricsRules.isValidID(""))
        XCTAssertFalse(MetricsRules.isValidID("not-a-uuid"))
        XCTAssertFalse(MetricsRules.isValidID("11111111222243338444555555555555"))
    }

    // MARK: The payload itself

    /// The whole point of the promise. If this test has to change, the notice
    /// in the app, the README and the privacy page all have to change with it.
    func test_theEntirePayloadIsThreeFields() throws {
        let report = MetricsReport(id: "11111111-2222-4333-8444-555555555555",
                                   cleaned: 41_203_847_610,
                                   version: "1.0.26")
        let data = try XCTUnwrap(MetricsRules.encode(report))
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            #"{"cleaned":41203847610,"id":"11111111-2222-4333-8444-555555555555","version":"1.0.26"}"#)
    }

    // MARK: The off switch

    func test_environmentSwitchRecognisesOffAndFailsClosed() {
        XCTAssertFalse(MetricsRules.suppresses(nil))
        for value in ["", "0", "false", "no", "off", "  ", "NO", " Off "] {
            XCTAssertFalse(MetricsRules.suppresses(value), "\(value) should not disable it")
        }
        // A typo has to stop reporting rather than quietly allow it.
        for value in ["1", "true", "yes", "ture"] {
            XCTAssertTrue(MetricsRules.suppresses(value), "\(value) should disable it")
        }
    }
}
