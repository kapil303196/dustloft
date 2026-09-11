import SwiftUI

struct RootView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var metrics: Metrics
    @StateObject private var engine: ScanEngine
    // A List(selection:) bound to String? needs String tags, never String?.
    // Overview therefore gets a real id rather than nil.
    @State private var selection: String = "overview"
    @State private var showReview = false
    /// nil = review everything selected; a category id = review just that section.
    @State private var reviewScope: String? = nil
    @State private var showWelcome = false
    @State private var showSummary = false
    @StateObject private var updater = Updater()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    init(settings: Settings, metrics: Metrics) {
        self.settings = settings
        self.metrics = metrics
        _engine = StateObject(wrappedValue: ScanEngine(settings: settings))
    }

    private var presentCategories: [Category] {
        Category.all.filter { engine.items[$0.id]?.isEmpty == false || $0.alwaysVisible }
    }

    private var currentTitle: String {
        if selection == "overview" { return "Overview" }
        return Category.all.first { $0.id == selection }?.title ?? "Overview"
    }

    private var currentSubtitle: String {
        if engine.isScanning { return engine.progressText.isEmpty ? "Scanning…" : engine.progressText }
        if selection == "overview" {
            return "\(Bytes.fmt(engine.volume.free)) free of \(Bytes.fmt(engine.volume.total))"
        }
        let list = engine.items[selection] ?? []
        let b = list.filter { !$0.isAdvisory }.reduce(Int64(0)) { $0 + $1.bytes }
        return "\(list.count) item\(list.count == 1 ? "" : "s") · \(Bytes.fmt(b))"
    }

    private var slices: [(Category, Int64)] {
        Category.all
            .filter { engine.items[$0.id]?.isEmpty == false
                      && !ScanEngine.lensCategories.contains($0.id) }
            .compactMap { cat in
            let b = (engine.items[cat.id] ?? []).filter { !$0.isAdvisory }.reduce(0) { $0 + $1.bytes }
            return b > 0 ? (cat, b) : nil
        }.sorted { $0.1 > $1.1 }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Group {
                if selection == "overview" {
                    overview
                } else if let cat = Category.all.first(where: { $0.id == selection }) {
                    CategoryDetailView(category: cat, engine: engine) {
                        reviewScope = cat.id
                        showReview = true
                    }
                } else {
                    overview
                }
            }
            .background(DS.bg)
        }
        .navigationTitle(currentTitle)
        .navigationSubtitle(currentSubtitle)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { actionBar }
        .sheet(isPresented: $showReview) {
            ReviewSheet(engine: engine, metrics: metrics,
                        isPresented: $showReview, scope: reviewScope)
        }
        .sheet(isPresented: $showSummary) {
            SummarySheet(engine: engine, isPresented: $showSummary)
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeSheet(isPresented: $showWelcome) {
                Task { await engine.scan() }
            }
        }
        .task {
            // Ask once, on first run only. After that a dismissible banner
            // carries the message — never a sheet on every launch.
            if !hasSeenWelcome {
                hasSeenWelcome = true
                showWelcome = true
                return
            }
            // Cached results are shown straight away; a fresh scan only starts
            // when they are genuinely old.
            if engine.isStale { await engine.scan() }
            await updater.check(silent: true)
            metrics.reportIfNeeded()
        }
        .task {
            // The daily beat only happens if something asks on the day, and the
            // only things that ask are launch and a clean. Without this, an app
            // left open for a week reports once, and "about once a day" — which
            // the notice, the README and the privacy page all say — is false.
            // reportIfNeeded is throttled, so an hourly nudge costs nothing.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
                if Task.isCancelled { break }
                metrics.reportIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dustloftCheckUpdates)) { _ in
            Task { await updater.check() }
        }
        .alert("Updates", isPresented: Binding(
            get: { updater.message != nil },
            set: { if !$0 { updater.message = nil } })
        ) {
            Button("OK", role: .cancel) { updater.message = nil }
        } message: {
            Text(updater.message ?? "")
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Overview", systemImage: "chart.pie.fill")
                    .tag("overview")
            }
            let everyone = presentCategories.filter { $0.audience == .everyone }
            let dev = presentCategories.filter { $0.audience == .developer }
            if !everyone.isEmpty {
                Section("Your Mac") {
                    ForEach(everyone) { cat in
                        SidebarRow(category: cat, items: engine.items[cat.id] ?? [])
                            .tag(cat.id)
                    }
                }
            }
            if !dev.isEmpty {
                Section("Developer") {
                    ForEach(dev) { cat in
                        SidebarRow(category: cat, items: engine.items[cat.id] ?? [])
                            .tag(cat.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 232)
    }

    // MARK: Overview

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                hero

                if updater.updateAvailable {
                    UpdateBanner(updater: updater).padding(.bottom, DS.s4)
                }

                if !metrics.noticeSeen && !Metrics.suppressedByEnvironment {
                    MetricsNotice(metrics: metrics).padding(.bottom, DS.s4)
                }

                if engine.permissionDenied {
                    PermissionBanner(showWelcome: $showWelcome)
                        .padding(.bottom, DS.s6)
                }

                if engine.isScanning && slices.isEmpty {
                    sectionHeader("Looking through your Mac", engine.progressText)
                    ScanningPlaceholder(progressText: engine.progressText, progress: engine.progress)
                } else if slices.isEmpty {
                    EmptyStateView(
                        symbol: "sparkles",
                        title: "Nothing worth dustlofting",
                        message: "Dustloft looked through caches, build output, leftovers and downloads and found nothing above 8 MB. Your Mac is in good shape.",
                        action: ("Scan again", { Task { await engine.scan() } })
                    )
                    .frame(height: 300)
                } else {
                    sectionHeader("Where your space is going", nil)
                    CompositionBar(slices: slices)
                        .padding(.bottom, DS.s7)
                        .animation(DS.motion(DS.spring, reduce: reduceMotion), value: engine.totalFound)

                    sectionHeader("Choose what to clean", "Nothing is removed until you review it")
                    VStack(spacing: 0) {
                        ForEach(Array(slices.enumerated()), id: \.element.0.id) { idx, pair in
                            let (cat, bytes) = pair
                            Button {
                                selection = cat.id
                            } label: {
                                OverviewRow(category: cat, bytes: bytes,
                                            count: (engine.items[cat.id] ?? []).count,
                                            picked: (engine.items[cat.id] ?? []).filter { $0.selected }.count)
                            }
                            .buttonStyle(.plain)
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .offset(y: 8)),
                                removal: .opacity.combined(with: .scale(scale: 0.98))))
                            .animation(DS.staggered(idx, reduce: reduceMotion), value: cat.id)
                            if idx < slices.count - 1 {
                                Divider().opacity(0.5).padding(.leading, 46)
                            }
                        }
                    }
                    .padding(.bottom, DS.s7)
                }

                SafetyNote()

                HStack(spacing: DS.s2) {
                    Text("Dustloft \(updater.current)")
                        .font(DS.caption()).foregroundStyle(DS.textFaint)
                    if let l = updater.latest, !updater.updateAvailable {
                        Text("· latest release \(l)")
                            .font(DS.caption()).foregroundStyle(DS.textFaint)
                    }
                    Button("Check for updates") { Task { await updater.check() } }
                        .buttonStyle(.link)
                        .font(DS.caption())
                    MetricsFooterControl(metrics: metrics)
                    Spacer()
                }
                .padding(.top, DS.s3)
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.horizontal, DS.s6)
            .padding(.top, DS.s5)
            .padding(.bottom, DS.s7)
            .frame(maxWidth: .infinity)
        }
    }

    /// The one number allowed to shout, and the only place it appears.
    private var hero: some View {
        VStack(alignment: .leading, spacing: DS.s4) {
            HStack(alignment: .firstTextBaseline, spacing: DS.s2) {
                Text(freeValue)
                    .font(.system(size: 44, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(DS.text)
                    .contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 0) {
                    Text(freeUnit).font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(DS.text)
                    Text("free").font(.system(size: 12)).foregroundStyle(DS.textDim)
                }
                .padding(.bottom, 4)
                Spacer()
            }

            StorageMeter(volume: engine.volume,
                         reclaimable: engine.totalFound,
                         selected: engine.totalSelected)

            // The one-click path for anyone who does not want to read a list.
            // It still routes through review — Dustloft never deletes unasked —
            // but everything is pre-selected and one confirmation away.
            if engine.lastScan != nil {
                VStack(alignment: .leading, spacing: DS.s2) {
                    HStack(spacing: DS.s2) {
                        Button {
                            engine.deselectEverything()
                            engine.selectEverythingSafe()
                            reviewScope = nil
                            showReview = true
                        } label: {
                            HStack(spacing: DS.s2) {
                                Image(systemName: "wand.and.sparkles")
                                Text("Quick clean")
                                Text(Bytes.fmt(engine.totalSafe))
                                    .font(DS.mono(12, .bold)).opacity(0.85)
                            }
                        }
                        .buttonStyle(PrimaryButton())
                        .disabled(engine.totalSafe == 0)
                        .help(engine.totalSafe == 0
                              ? "Nothing safe to clean automatically right now"
                              : "Reviews and removes only items that rebuild themselves. Nothing permanent is included.")

                        if engine.totalSafe > 0 {
                            Button("Select without cleaning") {
                                withAnimation(DS.quick) { engine.selectEverythingSafe() }
                            }
                            .buttonStyle(SecondaryButton())
                        }

                        if engine.totalSelected > 0 {
                            Button("Clear") {
                                withAnimation(DS.quick) { engine.deselectEverything() }
                            }
                            .buttonStyle(SecondaryButton())
                        }
                        Spacer()
                    }
                    HStack(spacing: DS.s1 + 2) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 9)).foregroundStyle(DS.safe)
                        Text(engine.totalSafe == 0
                             ? "Nothing to clean automatically — everything left needs you to look at it first."
                             : "Quick clean only touches caches and build output that come back on their own. Nothing permanent, nothing needing your judgement.")
                            .font(DS.caption()).foregroundStyle(DS.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, DS.s1)
            }

            HStack(spacing: DS.s2) {
                StatChip(symbol: "internaldrive", label: "In use",
                         value: Bytes.fmt(engine.volume.used), tint: DS.textDim)
                if engine.totalFound > 0 {
                    StatChip(symbol: "sparkles", label: "Reclaimable",
                             value: Bytes.fmt(engine.totalFound), tint: DS.safe,
                             action: { showSummary = true })
                }
                if engine.totalSelected > 0 {
                    StatChip(symbol: "checkmark.circle.fill", label: "Selected",
                             value: Bytes.fmt(engine.totalSelected), tint: DS.accent)
                }
                if metrics.lifetimeCleaned > 0 {
                    StatChip(symbol: "clock.arrow.circlepath", label: "Cleaned so far",
                             value: Bytes.fmt(metrics.lifetimeCleaned), tint: DS.textDim)
                }
                Spacer()
            }
        }
        .padding(.bottom, DS.s7)
    }

    private var freeValue: String {
        let s = Bytes.fmt(engine.volume.free)
        return s.split(separator: " ").first.map(String.init) ?? s
    }
    private var freeUnit: String {
        let s = Bytes.fmt(engine.volume.free)
        return s.split(separator: " ").dropFirst().first.map(String.init) ?? ""
    }

    private func sectionHeader(_ title: String, _ sub: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
            if let sub, !sub.isEmpty {
                Text(sub).font(DS.caption()).foregroundStyle(DS.textDim)
            }
        }
        .padding(.bottom, DS.s3)
    }

    // MARK: Toolbar + action bar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await engine.scan() }
            } label: {
                HStack(spacing: DS.s1 + 2) {
                    if engine.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(engine.isScanning ? "Scanning…" : "Rescan")
                }
            }
            .disabled(engine.isScanning)
            .help("Scan again for reclaimable space")
        }
    }

    private var actionBar: some View {
        HStack(spacing: DS.s4) {
            if engine.isScanning {
                ProgressView(value: engine.progress)
                    .frame(width: 160)
                Text(engine.progressText.isEmpty ? "Scanning…" : engine.progressText)
                    .font(DS.body()).foregroundStyle(DS.textDim)
            } else if engine.totalSelected > 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.accent)
                Text("\(engine.selectedItems.count) item\(engine.selectedItems.count == 1 ? "" : "s") selected")
                    .font(DS.body()).foregroundStyle(DS.text)
                Text(Bytes.fmt(engine.totalSelected))
                    .font(DS.mono(14, .bold)).foregroundStyle(DS.accent)
                    .contentTransition(.numericText())
            } else if let rel = engine.lastScanDescription {
                HStack(spacing: DS.s1 + 2) {
                    Image(systemName: engine.isStale ? "clock.badge.exclamationmark" : "clock")
                        .font(.system(size: 10))
                    Text("Scanned \(rel)")
                    if engine.isStale {
                        Text("· may be out of date").foregroundStyle(DS.warn)
                    }
                }
                .font(DS.caption()).foregroundStyle(DS.textDim)
            }

            Spacer()

            Button("Review and clean…") { reviewScope = nil; showReview = true }
                .buttonStyle(PrimaryButton())
                .disabled(engine.totalSelected == 0 || engine.isScanning)
                .keyboardShortcut(.return, modifiers: .command)
        }
        .animation(DS.quick, value: engine.totalSelected)
        .padding(.horizontal, DS.s5)
        .padding(.vertical, DS.s3)
        .background(.bar)
        .overlay(Divider(), alignment: .top)
    }
}

// MARK: - Rows

struct SidebarRow: View {
    let category: Category
    let items: [ScanItem]
    private var bytes: Int64 { items.filter { !$0.isAdvisory }.reduce(0) { $0 + $1.bytes } }
    private var picked: Int { items.filter { $0.selected }.count }

    var body: some View {
        HStack(spacing: DS.s2) {
            Image(systemName: category.symbol)
                .font(.system(size: 12))
                .foregroundStyle(category.hue)
                .frame(width: 18)
            Text(category.title).font(DS.body())
            Spacer(minLength: DS.s2)
            if picked > 0 {
                Circle().fill(DS.accent).frame(width: 6, height: 6)
            }
            if bytes > 0 {
                Text(Bytes.fmt(bytes))
                    .font(DS.mono(11, .medium))
                    .foregroundStyle(DS.textDim)
            }
        }
        .accessibilityLabel("\(category.title), \(Bytes.fmt(bytes))")
    }
}

struct OverviewRow: View {
    let category: Category
    let bytes: Int64
    let count: Int
    var picked: Int = 0
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(category.hue.opacity(hovering ? 0.24 : 0.15))
                Image(systemName: category.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(category.hue)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.text)
                HStack(spacing: DS.s1 + 2) {
                    Text("\(count) item\(count == 1 ? "" : "s")")
                        .font(DS.caption()).foregroundStyle(DS.textDim)
                    if picked > 0 {
                        Text("· \(picked) selected")
                            .font(DS.caption().weight(.medium)).foregroundStyle(DS.accent)
                    }
                }
            }

            Spacer(minLength: DS.s3)
            TierBadge(tier: category.tier)
            Text(Bytes.fmt(bytes))
                .font(DS.mono(13, .semibold))
                .foregroundStyle(DS.text)
                .frame(minWidth: 82, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? DS.textDim : DS.textFaint)
        }
        .padding(.vertical, DS.s3)
        .padding(.horizontal, DS.s3)
        .background(
            RoundedRectangle(cornerRadius: DS.rMd, style: .continuous)
                .fill(hovering ? DS.surfaceAlt : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { h in
            if reduceMotion { hovering = h }
            else { withAnimation(DS.quick) { hovering = h } }
        }
    }
}

struct StatChip: View {
    let symbol: String
    let label: String
    let value: String
    let tint: Color
    /// When set the chip becomes a real control. It looked tappable before and
    /// wasn't, which is worse than either alternative.
    var action: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
                .onHover { h in withAnimation(DS.quick) { hovering = h } }
                .help("See what makes up this figure")
        } else {
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: DS.s1 + 2) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(label).font(DS.caption())
            Text(value).font(DS.mono(11, .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, DS.s3)
        .padding(.vertical, DS.s1 + 3)
        .background(Capsule().fill(hovering ? DS.raised : DS.surfaceAlt))
        .overlay(Capsule().strokeBorder(hovering ? tint.opacity(0.5) : DS.border, lineWidth: 1))
        .contentShape(Capsule())
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Supporting views

struct ScanningPlaceholder: View {
    let progressText: String
    let progress: Double
    var body: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            HStack(spacing: DS.s2) {
                ProgressView().controlSize(.small)
                Text(progressText.isEmpty ? "Scanning…" : progressText)
                    .font(DS.body()).foregroundStyle(DS.text)
            }
            ProgressView(value: progress)
            // Skeleton rows, so the panel has shape while results stream in.
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: DS.s3) {
                    RoundedRectangle(cornerRadius: DS.rSm).fill(DS.surfaceAlt).frame(width: 30, height: 30)
                    RoundedRectangle(cornerRadius: 4).fill(DS.surfaceAlt).frame(height: 10)
                    Spacer()
                    RoundedRectangle(cornerRadius: 4).fill(DS.surfaceAlt).frame(width: 60, height: 10)
                }
            }
        }
    }
}

struct PermissionBanner: View {
    @Binding var showWelcome: Bool
    var body: some View {
        Card(padding: DS.s4) {
            HStack(alignment: .top, spacing: DS.s3) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 16)).foregroundStyle(DS.warn)
                VStack(alignment: .leading, spacing: DS.s1) {
                    Text("Dustloft does not have Full Disk Access")
                        .font(DS.body().weight(.semibold)).foregroundStyle(DS.text)
                    Text("Without it macOS asks separately for Desktop, Downloads and Documents, and sizes come out lower than reality. Granting it once covers everything. Note that macOS applies the permission only to a freshly launched app, and a Dustloft update changes the app's signature, so it has to be granted again after updating.")
                        .font(DS.caption()).foregroundStyle(DS.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Grant access") { showWelcome = true }
                    .buttonStyle(SecondaryButton())
            }
        }
    }
}

struct SafetyNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.s2) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 11)).foregroundStyle(DS.textFaint)
            Text("Dustloft never touches Dropbox, iCloud Drive or other synced folders, never deletes a .git directory, and never removes Docker volumes. Purgeable space is not listed, because no third-party app can reliably dustloft it.")
                .font(DS.caption()).foregroundStyle(DS.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.s1)
    }
}
