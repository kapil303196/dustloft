import XCTest
import Foundation
@testable import Reclaim

/// Covers the pure parsers and the safety predicates — the parts where a silent
/// mistake would either hide reclaimable space or, far worse, offer to delete
/// something protected.
final class ReclaimTests: XCTestCase {

    // MARK: docker system df

    func test_dockerUnits() {
        XCTAssertEqual(Scanners.parseDockerSize(["10.79GB"]), 10_790_000_000)
        XCTAssertEqual(Scanners.parseDockerSize(["512MB"]), 512_000_000)
        XCTAssertEqual(Scanners.parseDockerSize(["1.5TB"]), 1_500_000_000_000)
        XCTAssertEqual(Scanners.parseDockerSize(["58.7kB"]), 58_700)
        XCTAssertEqual(Scanners.parseDockerSize(["0B"]), 0)
    }

    func test_dockerPercentage() {
        XCTAssertEqual(Scanners.parseDockerSize(["12", "5", "21.57GB", "10.79GB", "(50%)"]), 10_790_000_000)
    }

    func test_dockerGarbage() {
        XCTAssertNil(Scanners.parseDockerSize(["Images", "TOTAL"]))
        XCTAssertNil(Scanners.parseDockerSize([]))
    }

    func test_dockerJSONExcludesVolumes() {
        let out = """
        {"Type":"Images","TotalCount":"12","Size":"21.57GB","Reclaimable":"10.79GB (50%)"}
        {"Type":"Containers","TotalCount":"8","Size":"90.11kB","Reclaimable":"53.25kB (59%)"}
        {"Type":"Local Volumes","TotalCount":"39","Size":"1.599GB","Reclaimable":"792.9MB (49%)"}
        {"Type":"Build Cache","TotalCount":"0","Size":"0B","Reclaimable":"0B"}
        """
        XCTAssertEqual(Scanners.parseDockerJSON(out), 10_790_000_000 + 53_250)
    }

    func test_dockerJSONRejectsTable() {
        XCTAssertNil(Scanners.parseDockerJSON("TYPE  TOTAL  ACTIVE\nImages 12 5"))
    }

    // MARK: ollama list

    func test_ollamaParsing() {
        let out = """
        NAME               ID              SIZE      MODIFIED
        llama3.1:latest    46e0c10c039e    4.9 GB    2 months ago
        gemma4:latest      c6eb396dbd59    9.6 GB    5 months ago
        """
        let models = Scanners.parseOllamaList(out)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models[0].name, "llama3.1:latest")
        XCTAssertEqual(models[0].bytes, 4_900_000_000)
        XCTAssertEqual(models[0].modified, "2 months ago")
        XCTAssertEqual(models[1].bytes, 9_600_000_000)
    }

    func test_ollamaEmpty() {
        XCTAssertTrue(Scanners.parseOllamaList("NAME    ID    SIZE    MODIFIED \n").isEmpty)
    }

    // MARK: updater

    func test_versions() {
        XCTAssertTrue(Updater.isNewer("v1.0.3", than: "1.0.0"))
        XCTAssertTrue(Updater.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(Updater.isNewer("2.0", than: "1.9.9"))
        XCTAssertFalse(Updater.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("1.0.0", than: "1.0.1"))
        // A shorter version string is not automatically older.
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
    }

    // MARK: exclusions — the rules that keep synced folders safe

    @MainActor
    func test_exclusions() {
        let s = Settings()
        let home = NSHomeDirectory()
        for p in [home + "/Dropbox",
                  home + "/Dropbox/Family Room/big.csv",
                  home + "/Library/Mobile Documents/anything",
                  home + "/Library/CloudStorage/OneDrive",
                  home + "/Library/Application Support/BraveSoftware",
                  home + "/Library/Application Support/BraveSoftware/Brave-Browser/Default"] {
            XCTAssertTrue(s.isExcluded(p), "\(p) must never be offered for deletion")
        }
    }

    @MainActor
    func test_hardExclusionsWin() {
        let s = Settings()
        s.exclusions = []
        XCTAssertTrue(s.isHardExcluded(NSHomeDirectory() + "/Dropbox/x"))
    }

    @MainActor
    func test_lookalikePrefix() {
        let s = Settings()
        XCTAssertFalse(s.isExcluded(NSHomeDirectory() + "/Library/Caches/Google"))
        XCTAssertFalse(s.isExcluded(NSHomeDirectory() + "/DropboxNotReally"))
    }

    // MARK: git safety — the check that saved a repository

    func test_onlyCopy() {
        let g = GitSafety(remoteRefCount: 0, uncommitted: 15, hasRemote: true)
        XCTAssertTrue(g.isOnlyCopy)
        XCTAssertEqual(g.badge?.0, "Only copy — nothing pushed")
    }

    func test_pushed() {
        let g = GitSafety(remoteRefCount: 7, uncommitted: 0, hasRemote: true)
        XCTAssertFalse(g.isOnlyCopy)
        XCTAssertEqual(g.badge?.0, "Pushed to remote")
    }

    func test_uncheckedRemote() {
        let g = GitSafety(remoteRefCount: nil, uncommitted: 0, hasRemote: true)
        XCTAssertFalse(g.isOnlyCopy)
    }

    // MARK: rows

    func test_advisoryRows() {
        let item = ScanItem(name: "x", path: "/tmp/x", bytes: 1, detail: nil,
                            action: .removePath("/tmp/x"), tier: .permanent)
        XCTAssertFalse(item.isAdvisory)
        let advisory = ScanItem(name: "y", path: "/tmp/y", bytes: 0, detail: nil,
                                action: .advisory("echo hi"), tier: .admin)
        XCTAssertTrue(advisory.isAdvisory)
    }
}
