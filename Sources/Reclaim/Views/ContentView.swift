import SwiftUI

struct RootView: View {
    @ObservedObject var settings: Settings
    @StateObject private var engine: ScanEngine
    @State private var selection: String? = nil       // nil == Overview
    @State private var showReview = false

    init(settings: Settings) {
        self.settings = settings
        _engine = StateObject(wrappedValue: ScanEngine(settings: settings))
    }

    private var presentCategories: [Category] {
        Category.all.filter { (engine.items[$0.id]?.isEmpty == false) }
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
                if let sel = selection, let cat = Category.all.first(where: { $0.id == sel }) {
                    CategoryDetailView(category: cat, engine: engine)
                } else {
                    overview
                }
            }
            .background(DS.bg)
        }
        .navigationTitle("")
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { actionBar }
        .sheet(isPresented: $showReview) {
            ReviewSheet(engine: engine, isPresented: $showReview)
        }
        .task { if engine.lastScan == nil { await engine.scan() } }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("Overview", systemImage: "chart.pie.fill")
                    .tag(String?.none)
            }
            if !presentCategories.isEmpty {
                Section("Found") {
                    ForEach(presentCategories) { cat in
                        SidebarRow(category: cat, items: engine.items[cat.id] ?? [])
                            .tag(String?.some(cat.id))
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
            VStack(alignment: .leading, spacing: DS.s5) {
                Card {
                    StorageMeter(volume: engine.volume,
                                 reclaimable: engine.totalFound,
                                 selected: engine.totalSelected)
                }

                if engine.permissionDenied {
                    PermissionBanner()
                }

                if engine.isScanning && slices.isEmpty {
                    Card { ScanningPlaceholder(progressText: engine.progressText, progress: engine.progress) }
                } else if slices.isEmpty {
                    Card {
                        EmptyStateView(
                            symbol: "sparkles",
                            title: "Nothing worth reclaiming",
                            message: "Reclaim found no caches, build output or leftovers above 8 MB. Your disk is in good shape.",
                            action: ("Scan again", { Task { await engine.scan() } })
                        )
                        .frame(height: 220)
                    }
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: DS.s4) {
                            Text("What is taking the space")
                                .font(DS.heading()).foregroundStyle(DS.text)
                            CompositionBar(slices: slices)
                        }
                    }

                    Card {
                        VStack(alignment: .leading, spacing: DS.s3) {
                            Text("Categories").font(DS.heading()).foregroundStyle(DS.text)
                            ForEach(slices, id: \.0.id) { cat, bytes in
                                Button {
                                    withAnimation(DS.quick) { selection = cat.id }
                                } label: {
                                    OverviewRow(category: cat, bytes: bytes,
                                                count: (engine.items[cat.id] ?? []).count)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                SafetyNote()
            }
            .padding(DS.s5)
        }
    }

    // MARK: Toolbar + action bar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: DS.s2) {
                Image(systemName: "sparkles.rectangle.stack.fill").foregroundStyle(DS.accent)
                Text("Reclaim").font(DS.heading())
            }
        }
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
            Text(bytes > 0 ? Bytes.fmt(bytes) : "—")
                .font(DS.mono(11, .medium))
                .foregroundStyle(DS.textDim)
        }
        .accessibilityLabel("\(category.title), \(Bytes.fmt(bytes))")
    }
}

struct OverviewRow: View {
    let category: Category
    let bytes: Int64
    let count: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: DS.rSm, style: .continuous)
                    .fill(category.hue.opacity(0.16))
                Image(systemName: category.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(category.hue)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text(category.title).font(DS.body().weight(.medium)).foregroundStyle(DS.text)
                Text("\(count) item\(count == 1 ? "" : "s")")
                    .font(DS.caption()).foregroundStyle(DS.textDim)
            }
            Spacer()
            TierBadge(tier: category.tier)
            Text(Bytes.fmt(bytes)).font(DS.mono(13, .semibold)).foregroundStyle(DS.text)
                .frame(minWidth: 76, alignment: .trailing)
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.textFaint)
        }
        .padding(.vertical, DS.s2)
        .padding(.horizontal, DS.s2)
        .background(
            RoundedRectangle(cornerRadius: DS.rMd, style: .continuous)
                .fill(hovering ? DS.surfaceAlt : Color.clear)
        )
        .onHover { h in withAnimation(DS.quick) { hovering = h } }
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
                Button("Open Settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(u)
                    }
                }
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
