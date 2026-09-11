import Foundation
import Network

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
    /// The longest two attempts are ever allowed to be apart, however many
    /// have failed in a row. Low enough that a machine which has been offline
    /// for days is never far from reporting once it is back; high enough that
    /// an endpoint which is genuinely down is not being hammered by everyone.
    static let maxRetryInterval: TimeInterval = 2 * 60 * 60

    /// How long to wait before trying again, given how many attempts in a row
    /// have failed. Doubling from `minInterval`, capped.
    static func retryDelay(consecutiveFailures: Int,
                           minInterval: TimeInterval = MetricsRules.minInterval,
                           cap: TimeInterval = MetricsRules.maxRetryInterval) -> TimeInterval {
        guard consecutiveFailures > 0 else { return minInterval }
        // Clamped before shifting: 1 << 64 is undefined, and a machine left
        // offline for a month would otherwise get there.
        let doublings = min(consecutiveFailures, 20)
        return min(minInterval * TimeInterval(1 << doublings), cap)
    }

    /// Whether to attempt a report now.
    ///
    /// Two clocks, not one, and the difference is the whole of how this
    /// behaves offline. `lastAttempt` paces retries so a dead endpoint is not
    /// hammered. `lastSuccess` drives the daily beat — measured from the last
    /// report that actually landed, so a week with no connection does not
    /// become a week of pushing the next one further away.
    static func shouldReport(now: Date,
                             lastAttempt: Date?,
                             lastSuccess: Date?,
                             reportedTotal: Int64,
                             currentTotal: Int64,
                             consecutiveFailures: Int,
                             minInterval: TimeInterval = MetricsRules.minInterval,
                             heartbeat: TimeInterval = MetricsRules.heartbeat,
                             cap: TimeInterval = MetricsRules.maxRetryInterval) -> Bool {
        guard let lastAttempt else { return true }
        let sinceAttempt = now.timeIntervalSince(lastAttempt)
        // A clock that moved backwards would otherwise freeze reporting until
        // it caught up, which for a manually corrected clock can be months.
        if sinceAttempt < 0 { return true }

        let wait = retryDelay(consecutiveFailures: consecutiveFailures,
                              minInterval: minInterval, cap: cap)
        if sinceAttempt < wait { return false }

        // Nothing has ever landed. Keep trying on that cycle: an install that
        // was offline the first time it ran does not exist yet, and counting
        // installs is the entire point.
        guard let lastSuccess else { return true }

        // Something the server has not been told about.
        if currentTotal > reportedTotal { return true }

        let sinceSuccess = now.timeIntervalSince(lastSuccess)
        return sinceSuccess < 0 || sinceSuccess >= heartbeat
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
            // Nine digits, matching the server. Four would have dropped every
            // install into "unknown" at release 1.0.10000 — the build number
            // is a CI run counter and only goes up.
            guard (1...9).contains(part.count),
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
        /// When the last attempt was made, landed or not. Named for what it
        /// was in 1.0.44 so an install updating from it keeps its pacing.
        static let lastAttemptAt = "metrics.lastReportAt"
        /// When a report last actually landed. The daily beat runs off this.
        static let lastSuccessAt = "metrics.lastSuccessAt"
        /// Attempts that have failed in a row, for the backoff.
        static let failures      = "metrics.failures"
        static let noticeShownAt = "metrics.noticeShownAt"
        static let everReported  = "metrics.everReported"
    }

    private let defaults: UserDefaults
    private let endpoint: URL?

    /// Read once at construction, not on every access: `launchctl setenv` only
    /// affects processes launched afterwards, so it cannot change underneath a
    /// running app. Injected rather than read inline so a test is not at the
    /// mercy of whoever ran the documented opt-out on the machine it runs on.
    let isSuppressedByEnvironment: Bool
    /// Launch and a clean can both ask to report within moments of each other.
    private var reportInFlight = false
    /// Watches for the network coming back. Nil in tests, which pass no
    /// endpoint and have no business opening one.
    private var connectivity: NWPathMonitor?
    /// Whether the last path update said there was a usable network, so that
    /// "came back" can be told from "still up".
    private var wasOnline = true
    /// How long the first-run card gets to be read and acted on before the
    /// first report goes. Injected so tests need not wait it out.
    private let noticeGrace: TimeInterval

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

    init(defaults: UserDefaults = .standard,
         endpoint: URL? = Metrics.endpoint,
         suppressedByEnvironment: Bool = Metrics.suppressedByEnvironment,
         noticeGrace: TimeInterval = Metrics.defaultNoticeGrace) {
        self.defaults = defaults
        self.endpoint = endpoint
        self.isSuppressedByEnvironment = suppressedByEnvironment
        self.noticeGrace = noticeGrace
        self.optedOut = defaults.bool(forKey: Key.optedOut)
        self.noticeSeen = defaults.bool(forKey: Key.noticeSeen)
        self.noticeShown = defaults.bool(forKey: Key.noticeShown)
        self.lifetimeCleaned = Int64(defaults.integer(forKey: Key.cleanedTotal))

        // Only when there is somewhere to report to, which keeps every test in
        // this file from starting a network monitor it does not need.
        if endpoint != nil { watchConnectivity() }
    }

    // No deinit cancelling the monitor: this object is a @StateObject on the
    // App itself, so it lives as long as the process does and there is nothing
    // to tidy up before that. Reaching into main-actor state from a nonisolated
    // deinit to save nothing would be the wrong trade.

    /// Reports as soon as the machine has a network again.
    ///
    /// Everything here works offline already: scanning and cleaning never
    /// touch the network, a failed report is silent, and the total is
    /// cumulative so nothing is lost by one not landing. What was missing is
    /// the other half — noticing that the thing which made it fail has gone
    /// away. Without this, a laptop that was offline when it cleaned 40 GB
    /// waits for the next launch, clean, or fifteen-minute tick before trying
    /// again, and a Mac that is only ever online briefly might never coincide
    /// with one.
    private func watchConnectivity() {
        let monitor = NWPathMonitor()
        connectivity = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.wasOnline = online }
                // Only on the edge. A path update also arrives when the
                // interface changes while staying usable — Wi-Fi to Ethernet,
                // a VPN coming up — and reporting on each of those would be a
                // way to send far more often than "once a day" promises.
                guard online, !self.wasOnline else { return }
                // The reason every recent attempt failed has demonstrably
                // gone, so the backoff those failures built up is describing a
                // problem that no longer exists. Starting from a clean slate
                // is what makes coming back online mean reporting now rather
                // than in up to two hours.
                self.defaults.set(0, forKey: Key.failures)
                self.reportIfNeeded()
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
    }

    /// An escape hatch for anyone deploying this somewhere it must not phone
    /// home, without needing to open the app to say so. The instance reads this
    /// once at construction; prefer `isSuppressedByEnvironment` everywhere else.
    ///
    /// `nonisolated` because it is the default for `init`, and a default
    /// argument is evaluated wherever the initialiser is called — including
    /// `@StateObject private var metrics = Metrics()` in a struct's property
    /// initialiser, which is not on the main actor. Reading the process
    /// environment needs no isolation to be safe.
    nonisolated static var suppressedByEnvironment: Bool {
        MetricsRules.suppresses(ProcessInfo.processInfo.environment["DUSTLOFT_NO_METRICS"])
    }

    /// Reporting needs all four: not opted out, not disabled by the
    /// environment, the explanation already drawn, and — for the very first
    /// report only — that explanation readable for long enough to act on.
    var isReporting: Bool {
        !optedOut && !isSuppressedByEnvironment && noticeShown && firstReportDue
    }

    /// Whether the grace after the card appeared has passed.
    ///
    /// Only the first report waits. Deferring the *scheduled* first report was
    /// not enough on its own: cleaning something inside that window goes
    /// straight to `recordCleaned` → `reportIfNeeded`, which would mint the
    /// identifier and send before the button offering to stop it had been up
    /// for a second. The gate has to be on reporting itself, not on one caller.
    private var firstReportDue: Bool {
        guard defaults.double(forKey: Key.lastAttemptAt) == 0 else { return true }
        let shownAt = defaults.double(forKey: Key.noticeShownAt)
        guard shownAt > 0 else { return false }
        return Date().timeIntervalSince1970 - shownAt >= noticeGrace
    }

    /// Called by the notice card the first time it is drawn.
    func markNoticeShown() {
        guard !noticeShown else { return }
        noticeShown = true
        defaults.set(true, forKey: Key.noticeShown)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.noticeShownAt)

        // On a first run nothing else will ask again this session: the launch
        // path returns early to show the welcome sheet, before it reaches
        // reportIfNeeded. Without this, an install where someone looks once and
        // never reopens the app is never counted at all — which is the single
        // thing this was built to count. The wait is the grace above, which
        // `isReporting` enforces independently, so this is only what makes the
        // report happen once it expires.
        Task { [weak self] in
            guard let grace = self?.noticeGrace else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1_000_000_000))
            self?.reportIfNeeded()
        }
    }

    static let defaultNoticeGrace: TimeInterval = 30

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
        guard MetricsRules.shouldReport(
            now: now,
            lastAttempt: date(Key.lastAttemptAt),
            lastSuccess: lastSuccess,
            reportedTotal: Int64(defaults.integer(forKey: Key.reportedTotal)),
            currentTotal: total,
            consecutiveFailures: defaults.integer(forKey: Key.failures)) else { return }

        let report = MetricsReport(id: installID(), cleaned: total, version: Metrics.appVersion)
        reportInFlight = true
        // Stamped on the attempt, and used only to pace retries. Recorded
        // solely on success, an endpoint that is down would be retried from
        // every launch and every clean — a flood aimed at something already
        // struggling. The daily beat runs off Key.lastSuccessAt instead, so
        // failing does not push the next report further away.
        defaults.set(now.timeIntervalSince1970, forKey: Key.lastAttemptAt)

        Task { [weak self] in
            let delivered = await Metrics.send(report, to: endpoint)
            guard let self else { return }
            self.reportInFlight = false
            if delivered { self.markReported(total: total) } else { self.markFailed() }
        }
    }

    private func markReported(total: Int64) {
        // A high-water mark: a late reply must never drag it back down, or the
        // difference would be sent a second time and counted twice.
        let known = Int64(defaults.integer(forKey: Key.reportedTotal))
        defaults.set(Int(max(known, total)), forKey: Key.reportedTotal)
        // Distinct from reportedTotal, which a perfectly good first report of
        // zero bytes would leave at zero.
        defaults.set(true, forKey: Key.everReported)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.lastSuccessAt)
        defaults.set(0, forKey: Key.failures)
    }

    private func markFailed() {
        defaults.set(defaults.integer(forKey: Key.failures) + 1, forKey: Key.failures)
    }

    private func date(_ key: String) -> Date? {
        let stamp = defaults.double(forKey: key)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    /// When a report last landed.
    ///
    /// An install updating from 1.0.44 has reported but has no success stamp,
    /// because that build kept only the one clock. Its attempt stamp is the
    /// closest thing to the truth and is very nearly it, since the stamp was
    /// written moments before the report that set everReported.
    private var lastSuccess: Date? {
        if let recorded = date(Key.lastSuccessAt) { return recorded }
        return defaults.bool(forKey: Key.everReported) ? date(Key.lastAttemptAt) : nil
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
        config.timeoutIntervalForResource = 30
        // Fail immediately when there is no network rather than holding the
        // request open until one appears. Offline is a normal state here, not
        // an error to wait out: the total is cumulative, the path monitor
        // notices when connectivity returns, and a task parked indefinitely
        // would keep reportInFlight set and block every later attempt.
        config.waitsForConnectivity = false
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
