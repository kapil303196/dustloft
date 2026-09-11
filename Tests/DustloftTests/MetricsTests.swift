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
        // Releases are stamped from the CI run number, which only goes up.
        XCTAssertEqual(MetricsRules.sanitizedVersion("1.0.10000"), "1.0.10000")
        XCTAssertEqual(MetricsRules.sanitizedVersion("1.0.999999999"), "1.0.999999999")
    }

    func test_versionDropsAnythingElseRatherThanBeingRefused() {
        XCTAssertEqual(MetricsRules.sanitizedVersion(""), "")
        XCTAssertEqual(MetricsRules.sanitizedVersion("1.0.26-beta"), "")
        XCTAssertEqual(MetricsRules.sanitizedVersion("v1.0.26"), "")
        XCTAssertEqual(MetricsRules.sanitizedVersion("1.2.3.4.5"), "")
        XCTAssertEqual(MetricsRules.sanitizedVersion("1..2"), "")
        XCTAssertEqual(MetricsRules.sanitizedVersion("1234567890"), "")
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

    // MARK: The object itself

    /// A scratch defaults domain, so a test can never read or write the real one.
    private func scratchDefaults() throws -> (UserDefaults, String) {
        let name = "dustloft.tests.\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: name)), name)
    }

    /// The promise is that the card explains this before anything is sent. That
    /// only holds if the card having been drawn is what unlocks sending.
    @MainActor
    func test_nothingIsSentUntilTheNoticeHasBeenOnScreen() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let metrics = Metrics(defaults: defaults, endpoint: nil, suppressedByEnvironment: false)
        XCTAssertFalse(metrics.isReporting, "reported before the notice was ever drawn")

        metrics.markNoticeShown()
        XCTAssertTrue(metrics.isReporting)

        metrics.optedOut = true
        XCTAssertFalse(metrics.isReporting)
    }

    /// The environment switch has to win over everything else, including a
    /// notice that has been seen and a person who never opted out.
    @MainActor
    func test_theEnvironmentSwitchOverridesEverything() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let metrics = Metrics(defaults: defaults, endpoint: nil, suppressedByEnvironment: true)
        metrics.markNoticeShown()
        XCTAssertFalse(metrics.optedOut)
        XCTAssertFalse(metrics.isReporting)
    }

    @MainActor
    func test_theLifetimeTotalSurvivesRelaunch() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let first = Metrics(defaults: defaults, endpoint: nil, suppressedByEnvironment: false)
        first.recordCleaned(4_000)
        first.recordCleaned(1_500)
        first.recordCleaned(0)
        XCTAssertEqual(first.lifetimeCleaned, 5_500)

        XCTAssertEqual(Metrics(defaults: defaults, endpoint: nil, suppressedByEnvironment: false).lifetimeCleaned, 5_500)
    }

    /// Turning it off has to be sticky; a preference that resets on relaunch is
    /// worse than none, because it looks like a choice and is not one.
    @MainActor
    func test_theChoiceSurvivesRelaunch() throws {
        let (defaults, name) = try scratchDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let first = Metrics(defaults: defaults, endpoint: nil, suppressedByEnvironment: false)
        first.markNoticeShown()
        first.optedOut = true
        first.noticeSeen = true

        let second = Metrics(defaults: defaults, endpoint: nil, suppressedByEnvironment: false)
        XCTAssertTrue(second.optedOut)
        XCTAssertTrue(second.noticeSeen)
        XCTAssertTrue(second.noticeShown)
        XCTAssertFalse(second.isReporting)
    }

    // MARK: What a clean is allowed to count

    /// The published total is only ever fed measurements. Prune's own summary
    /// line is the measurement here; the scan estimate behind it is stale by
    /// design, because results are cached between launches.
    func test_dockerPruneIsCountedFromWhatItSaysItFreed() {
        let output = "Deleted Images:\nuntagged: nginx:latest\n\nTotal reclaimed space: 10.79GB\n"
        XCTAssertEqual(Cleaner.dockerReclaimed(output), 10_790_000_000)
        XCTAssertEqual(Cleaner.dockerReclaimed("Total reclaimed space: 0B"), 0)
    }

    /// Nothing to report is not the same as a number that could not be read,
    /// and neither may quietly fall back to the scan estimate.
    func test_dockerPruneCountsNothingWhenItSaidNothing() {
        XCTAssertEqual(Cleaner.dockerReclaimed(""), 0)
        XCTAssertEqual(Cleaner.dockerReclaimed("Deleted Images:\nuntagged: nginx"), 0)
    }

    /// "Gone" and "could not be reached" must not be the same answer: the first
    /// clears a row for free, and giving it for the second would turn an
    /// unmounted volume into a successful clean.
    func test_absentIsNotTheSameAsUnreachable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dustloft-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("thing")
        try Data("x".utf8).write(to: file)
        XCTAssertTrue(Cleaner.entryExists(file.path))

        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(Cleaner.entryExists(file.path))

        // A dangling symlink is a real directory entry that really does need
        // removing, so it has to read as present.
        let link = dir.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertTrue(Cleaner.entryExists(link.path))

        // A path under a directory that does not exist is absent, not
        // unanswerable — ENOENT either way.
        XCTAssertFalse(Cleaner.entryExists(dir.path + "/missing/deeper/thing"))
    }

    /// The one place the same bytes could be billed twice: Dustloft moves a
    /// permanent item to the Trash and counts it, the next scan offers that
    /// same file from the Trash, and emptying it there would count it again
    /// for space that is only freed once.
    func test_theTrashNeverCountsTwice() {
        let home = NSHomeDirectory()
        XCTAssertTrue(Cleaner.isInsideTrash(home + "/.Trash/holiday.mov"))
        XCTAssertTrue(Cleaner.isInsideTrash(home + "/.Trash"))
        XCTAssertTrue(Cleaner.isInsideTrash("/Volumes/Backup/.Trashes/501/old.dmg"))

        XCTAssertTrue(Cleaner.isInsideTrash("/.Trashes/501/old.dmg"))

        XCTAssertFalse(Cleaner.isInsideTrash(home + "/Movies/holiday.mov"))
        // A lookalike prefix is not a match.
        XCTAssertFalse(Cleaner.isInsideTrash(home + "/.Trashcan/thing"))
        XCTAssertFalse(Cleaner.isInsideTrash(home + "/Library/Caches/Trash/thing"))

        // This also decides whether a permanent item is moved to the Trash or
        // unlinked, so a .Trash component somewhere in the middle of a path is
        // not good enough — a sandboxed app's own is not the Trash.
        XCTAssertFalse(
            Cleaner.isInsideTrash(home + "/Library/Containers/com.x.y/Data/.Trash/big.mov"))
        XCTAssertFalse(Cleaner.isInsideTrash(home + "/Projects/.Trashes/note.txt"))
    }

    func test_targetPathIsTheOneTheActionTouches() {
        XCTAssertEqual(Cleaner.targetPath(of: .removePath("/a")), "/a")
        XCTAssertEqual(Cleaner.targetPath(of: .trashPath("/b")), "/b")
        XCTAssertEqual(Cleaner.targetPath(of: .removePathAdmin("/c")), "/c")
        XCTAssertEqual(Cleaner.targetPath(of: .gitGC("/d")), "/d")
        // No path means nothing to check against the Trash.
        XCTAssertNil(Cleaner.targetPath(of: .dockerPrune))
        XCTAssertNil(Cleaner.targetPath(of: .ollamaModel("llama3")))
        XCTAssertNil(Cleaner.targetPath(of: .adminShell("/usr/bin/mdutil -E /")))
    }

    /// Permanent items are routed to the Trash so the decision stays
    /// reversible — but a file already in the Trash cannot be sent there, and
    /// pretending otherwise clears the row while the file comes straight back.
    func test_theTrashIsNotSentToTheTrash() {
        let home = NSHomeDirectory()

        let media = ScanItem(name: "holiday.mov", path: home + "/Movies/holiday.mov",
                             bytes: 1, detail: "", action: .removePath(home + "/Movies/holiday.mov"),
                             tier: .permanent)
        guard case .trashPath = Cleaner.effectiveAction(for: media) else {
            return XCTFail("a permanent item should be routed to the Trash")
        }

        let alreadyThere = home + "/.Trash/holiday.mov"
        let trashed = ScanItem(name: "holiday.mov", path: alreadyThere, bytes: 1,
                               detail: "", action: .removePath(alreadyThere), tier: .permanent)
        guard case .removePath = Cleaner.effectiveAction(for: trashed) else {
            return XCTFail("emptying the Trash has to unlink, not re-trash")
        }
    }

    /// Trashing is a rename, so its size has to come from somewhere free.
    func test_aFileSizeCostsNothingAndADirectoryIsNotGuessedAt() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dustloft-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("recording.mov")
        try Data(repeating: 0, count: 4096).write(to: file)
        XCTAssertEqual(Cleaner.fileSizeNow(file.path), 4096)

        // A directory would need a tree walk, which is the thing this avoids.
        XCTAssertNil(Cleaner.fileSizeNow(dir.path))
        XCTAssertNil(Cleaner.fileSizeNow(dir.path + "/missing"))
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
