import Foundation

/// The exact and entire contents of a report.
///
/// Written as a type rather than assembled inline so that what leaves the
/// machine is a thing you can read in one place, and so the tests can assert on
/// the literal bytes. Adding a field here is a deliberate act with a visible
/// diff — which is the point.
struct MetricsReport: Codable, Equatable {
    /// A random identifier this copy generated for itself. Not derived from the
    /// hardware, the user, the network or anything else — a fresh UUID, whose
    /// only job is to stop one Mac being counted as a hundred.
    let id: String
    /// Bytes this copy has removed over its lifetime, cumulative. Counts items
    /// sent to the Trash as well as those deleted outright, which is why the UI
    /// says "cleaned" against this figure and never "freed".
    let cleaned: Int64
    /// Which build is running, so an update's reach can be seen.
    let version: String
}

/// The decisions, separated from the side effects.
///
/// Everything here is pure and free of the main actor, which is what makes the
/// throttling and the payload testable without a network, a clock or a UI.
enum MetricsRules {

    /// Matches the server's own ceiling. A total beyond this is a bug or a
    /// forgery; agreeing on the number here means the client never sends
    /// something the server will quietly change behind its back.
    static let maxCleaned: Int64 = 1_000_000_000_000_000   // 1 PB

    /// Report at most this often when the total has moved.
    static let minInterval: TimeInterval = 60
    /// Report this often even when nothing has changed, so that the version
    /// tally reflects installs that update but never clean anything again.
    static let heartbeat: TimeInterval = 24 * 60 * 60

    static func shouldReport(now: Date,
                             lastReport: Date?,
                             reportedTotal: Int64,
                             currentTotal: Int64,
                             minInterval: TimeInterval = MetricsRules.minInterval,
                             heartbeat: TimeInterval = MetricsRules.heartbeat) -> Bool {
        guard let lastReport else { return true }
        let elapsed = now.timeIntervalSince(lastReport)
        // A clock that moved backwards would otherwise freeze reporting until
        // it caught up, which for a manually corrected clock can be months.
        if elapsed < 0 { return true }
        if elapsed >= heartbeat { return true }
        return currentTotal > reportedTotal && elapsed >= minInterval
    }

    /// Saturating, because a total that wrapped past Int64 would be reported as
    /// negative and rejected forever afterwards.
    static func accumulate(_ total: Int64, _ add: Int64) -> Int64 {
        guard add > 0 else { return total }
        let (sum, overflowed) = total.addingReportingOverflow(add)
        return overflowed ? maxCleaned : min(sum, maxCleaned)
    }

    /// The server accepts up to four dot-separated numbers and nothing else.
    /// Anything unexpected is dropped rather than sent and refused, so a build
    /// with an odd version string still has its install counted.
    static func sanitizedVersion(_ raw: String) -> String {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return "" }
        for part in parts {
            guard (1...4).contains(part.count),
                  part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return "" }
        }
        return raw
    }

    /// Whether a `DUSTLOFT_NO_METRICS` value means "off". Anything that is not
    /// recognisably a negative counts as set, so a typo fails closed — towards
    /// sending nothing — rather than open.
    static func suppresses(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let value = raw.trimmingCharacters(in: .whitespaces).lowercased()
        return !(value.isEmpty || value == "0" || value == "false"
                 || value == "no" || value == "off")
    }

    static func isValidID(_ raw: String) -> Bool {
        guard raw.count == 36 else { return false }
        return UUID(uuidString: raw) != nil
    }

    static func encode(_ report: MetricsReport) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(report)
    }
}

/// Counts installs and reclaimed space, and nothing else.
///
/// Dustloft had no way of knowing how many Macs it runs on or whether it has
/// ever actually given anyone their disk back. This is the smallest thing that
/// answers both questions: a random identifier so one Mac is not counted as a
/// hundred, a running byte total, and the version. No account, no address, no
/// path, no file name — the whole payload is three fields and you can read them
/// in `MetricsReport` above.
///
/// It is on by default and off in one click. The first-run notice states what
/// is sent before anything is, `DUSTLOFT_NO_METRICS=1` disables it without
/// launching the app at all, and turning it off stops it permanently — there is
/// no final "goodbye" report.
@MainActor
final class Metrics: ObservableObject {

    nonisolated static let endpoint = URL(string: "https://dustloft.com/api/ping")

    private enum Key {
        static let optedOut      = "metrics.optedOut"
        static let noticeSeen    = "metrics.noticeSeen"
        static let noticeShown   = "metrics.noticeShown"
        static let installID     = "metrics.installID"
        static let cleanedTotal  = "metrics.cleanedTotal"
        static let reportedTotal = "metrics.reportedTotal"
        static let lastReportAt  = "metrics.lastReportAt"
    }

    private let defaults: UserDefaults
    private let endpoint: URL?
    /// Launch and a clean can both ask to report within moments of each other.
    private var reportInFlight = false

    /// Lifetime bytes reclaimed on this Mac. Tracked whether or not anything is
    /// ever reported, because it is worth showing the person who did it.
    @Published private(set) var lifetimeCleaned: Int64

    @Published var optedOut: Bool {
        didSet {
            guard optedOut != oldValue else { return }
            defaults.set(optedOut, forKey: Key.optedOut)
        }
    }

    /// Whether the one-time explanation has been dismissed. Controls the card,
    /// not the reporting — see `noticeShown` for that.
    @Published var noticeSeen: Bool {
        didSet {
            guard noticeSeen != oldValue else { return }
            defaults.set(noticeSeen, forKey: Key.noticeSeen)
        }
    }

    /// Whether the explanation has ever actually been on screen.
    ///
    /// Nothing is sent before it has. Without this, a first run where someone
    /// cleans immediately could report before the card had been drawn — which
    /// would make "it tells you before it sends anything" false in exactly the
    /// case where it matters most.
    @Published private(set) var noticeShown: Bool

    init(defaults: UserDefaults = .standard, endpoint: URL? = Metrics.endpoint) {
        self.defaults = defaults
        self.endpoint = endpoint
        self.optedOut = defaults.bool(forKey: Key.optedOut)
        self.noticeSeen = defaults.bool(forKey: Key.noticeSeen)
        self.noticeShown = defaults.bool(forKey: Key.noticeShown)
        self.lifetimeCleaned = Int64(defaults.integer(forKey: Key.cleanedTotal))
    }

    /// An escape hatch for anyone deploying this somewhere it must not phone
    /// home, without needing to open the app to say so.
    static var suppressedByEnvironment: Bool {
        MetricsRules.suppresses(ProcessInfo.processInfo.environment["DUSTLOFT_NO_METRICS"])
    }

    /// Reporting needs all three: not opted out, not disabled by the
    /// environment, and the explanation already seen at least once.
    var isReporting: Bool { !optedOut && !Metrics.suppressedByEnvironment && noticeShown }

    /// Called by the notice card the first time it is drawn.
    func markNoticeShown() {
        guard !noticeShown else { return }
        noticeShown = true
        defaults.set(true, forKey: Key.noticeShown)
    }

    static var appVersion: String {
        MetricsRules.sanitizedVersion(
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
    }

    // MARK: - Recording

    /// Adds to this Mac's lifetime total and reports if it is time to.
    func recordCleaned(_ bytes: Int64) {
        guard bytes > 0 else { return }
        lifetimeCleaned = MetricsRules.accumulate(lifetimeCleaned, bytes)
        defaults.set(Int(lifetimeCleaned), forKey: Key.cleanedTotal)
        reportIfNeeded()
    }

    /// Sends at most one report, in the background, and never blocks anything.
    /// A failure is left alone: the total is cumulative, so the next successful
    /// report carries whatever this one would have.
    func reportIfNeeded(now: Date = Date()) {
        guard !reportInFlight, isReporting, let endpoint = self.endpoint else { return }

        let total = lifetimeCleaned
        let stamp = defaults.double(forKey: Key.lastReportAt)
        let last = stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        guard MetricsRules.shouldReport(
            now: now,
            lastReport: last,
            reportedTotal: Int64(defaults.integer(forKey: Key.reportedTotal)),
            currentTotal: total) else { return }

        let report = MetricsReport(id: installID(), cleaned: total, version: Metrics.appVersion)
        reportInFlight = true
        // Stamped on the attempt rather than on success. Recorded only when it
        // worked, an endpoint that is down would be retried on every launch and
        // every clean — a flood aimed at something already struggling. The
        // total is cumulative, so nothing is lost by waiting for the next turn.
        defaults.set(now.timeIntervalSince1970, forKey: Key.lastReportAt)

        Task { [weak self] in
            let delivered = await Metrics.send(report, to: endpoint)
            guard let self else { return }
            self.reportInFlight = false
            if delivered { self.markReported(total: total) }
        }
    }

    private func markReported(total: Int64) {
        // A high-water mark: a late reply must never drag it back down, or the
        // difference would be sent a second time and counted twice.
        let known = Int64(defaults.integer(forKey: Key.reportedTotal))
        defaults.set(Int(max(known, total)), forKey: Key.reportedTotal)
    }

    /// Created on first use rather than at launch, so a person who turns this
    /// off before anything is ever sent never has an identifier at all.
    private func installID() -> String {
        if let existing = defaults.string(forKey: Key.installID),
           MetricsRules.isValidID(existing) {
            return existing
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: Key.installID)
        return fresh
    }

    // MARK: - Transport

    /// Deliberately ephemeral: no cookie jar, no cache, nothing about this
    /// request is written to disk or carried into the next launch. The
    /// User-Agent is replaced too, because the default one carries the macOS
    /// version and this is meant to send three fields and no fourth.
    nonisolated static func send(_ report: MetricsReport, to endpoint: URL) async -> Bool {
        guard let body = MetricsRules.encode(report) else { return false }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Dustloft", forHTTPHeaderField: "User-Agent")
        request.httpBody = body
        request.timeoutInterval = 10

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }
}
