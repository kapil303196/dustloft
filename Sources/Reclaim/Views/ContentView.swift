import SwiftUI

struct RootView: View {
    @ObservedObject var settings: Settings
    @StateObject private var engine: ScanEngine
    // A List(selection:) bound to String? needs String tags, never String?.
    // Overview therefore gets a real id rather than nil.
    @State private var selection: String = "overview"
    @State private var showReview = false
    @State private var showWelcome = false
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false

    init(settings: Settings) {
        self.settings = settings
        _engine = StateObject(wrappedValue: ScanEngine(settings: settings))
    }

    private var presentCategories: [Category] {
        Category.all.filter { (engine.items[$0.id]?.isEmpty == false) }
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
        presentCategories.compactMap { cat in
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
                    CategoryDetailView(category: cat, engine: engine)
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
            ReviewSheet(engine: engine, isPresented: $showReview)
        }
        .sheet(isPresented: $showWelcome) {
            WelcomeSheet(isPresented: $showWelcome) {
                hasSeenWelcome = true
                Task { await engine.scan() }
            }
        }
        .task {
            // Ask once, up front, for the one permission that matters.
            if !hasSeenWelcome || !Permissions.hasFullDiskAccess() {
                if !Permissions.hasFullDiskAccess() || !hasSeenWelcome {
                    showWelcome = true
                    return
                }
            }
            if engine.lastScan == nil { await engine.scan() }
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
                        title: "Nothing worth reclaiming",
                        message: "Reclaim looked through caches, build output, leftovers and downloads and found nothing above 8 MB. Your Mac is in good shape.",
                        action: ("Scan again", { Task { await engine.scan() } })
                    )
                    .frame(height: 300)
                } else {
                    sectionHeader("Where your space is going", nil)
                    CompositionBar(slices: slices)
                        .padding(.bottom, DS.s7)

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
                            if idx < slices.count - 1 {
                                Divider().opacity(0.5).padding(.leading, 46)
                            }
                        }
                    }
                    .padding(.bottom, DS.s7)
                }

                SafetyNote()
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

            HStack(spacing: DS.s2) {
                StatChip(symbol: "internaldrive", label: "In use",
                         value: Bytes.fmt(engine.volume.used), tint: DS.textDim)
                if engine.totalFound > 0 {
                    StatChip(symbol: "sparkles", label: "Reclaimable",
                             value: Bytes.fmt(engine.totalFound), tint: DS.safe)
                }
                if engine.totalSelected > 0 {
                    StatChip(symbol: "checkmark.circle.fill", label: "Selected",
                             value: Bytes.fmt(engine.totalSelected), tint: DS.accent)
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
            } else if let last = engine.lastScan {
                Text("Last scanned \(last.formatted(date: .omitted, time: .shortened))")
                    .font(DS.caption()).foregroundStyle(DS.textDim)
            }

            Spacer()

            Button("Review and clean…") { showReview = true }
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
    var body: some View {
        HStack(spacing: DS.s1 + 2) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(label).font(DS.caption())
            Text(value).font(DS.mono(11, .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, DS.s3)
        .padding(.vertical, DS.s1 + 3)
        .background(
            Capsule().fill(DS.surfaceAlt)
        )
        .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
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
                    Text("Some folders could not be read")
                        .font(DS.body().weight(.semibold)).foregroundStyle(DS.text)
                    Text("Grant Reclaim Full Disk Access so it can measure the Trash, container and app-data folders. Sizes shown may be lower than reality until you do.")
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
            Text("Reclaim never touches Dropbox, iCloud Drive or other synced folders, never deletes a .git directory, and never removes Docker volumes. Purgeable space is not listed, because no third-party app can reliably reclaim it.")
                .font(DS.caption()).foregroundStyle(DS.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.s1)
    }
}
