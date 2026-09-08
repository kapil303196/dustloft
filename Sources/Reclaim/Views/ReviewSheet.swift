import SwiftUI

struct ReviewSheet: View {
    @ObservedObject var engine: ScanEngine
    @Binding var isPresented: Bool
    /// nil reviews everything selected; a category id reviews just that section.
    var scope: String? = nil
    @StateObject private var cleaner = Cleaner()
    @State private var acknowledgePermanent = false

    /// Selected rows, grouped by the section they came from and ordered with
    /// the riskiest sections first so nothing dangerous hides below the fold.
    private var groups: [(Category, [ScanItem])] {
        let keys = scope.map { [$0] } ?? Array(engine.items.keys)
        return keys.compactMap { key -> (Category, [ScanItem])? in
            let picked = (engine.items[key] ?? []).filter { $0.selected }
            guard !picked.isEmpty else { return nil }
            return (Category.find(key), picked)
        }
        .sorted { a, b in
            func rank(_ t: SafetyTier) -> Int {
                switch t { case .permanent: return 0; case .admin: return 1; case .regenerable: return 2 }
            }
            let ra = rank(a.0.tier), rb = rank(b.0.tier)
            if ra != rb { return ra < rb }
            return a.1.reduce(0) { $0 + $1.bytes } > b.1.reduce(0) { $0 + $1.bytes }
        }
    }

    private var items: [ScanItem] { groups.flatMap { $0.1 } }
    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    private var permanent: [ScanItem] { items.filter { $0.tier == .permanent } }
    private var admin: [ScanItem] { items.filter { $0.tier == .admin } }
    private var regen: [ScanItem] { items.filter { $0.tier == .regenerable } }
    private var blocked: Bool { !permanent.isEmpty && !acknowledgePermanent }

    var body: some View {
        VStack(spacing: 0) {
            if cleaner.finished      { results }
            else if cleaner.isRunning { running }
            else                      { review }
        }
        .frame(width: 620, height: 560)
        .background(DS.bg)
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.s2) {
                Text(scope == nil ? "Review before cleaning"
                                  : "Review \(Category.find(scope!).title)")
                    .font(DS.title()).foregroundStyle(DS.text)
                Text("\(items.count) item\(items.count == 1 ? "" : "s") in \(groups.count) section\(groups.count == 1 ? "" : "s") · \(Bytes.fmt(totalBytes)) will be freed")
                    .font(DS.body()).foregroundStyle(DS.textDim)
            }
            .padding(DS.s5)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.s4) {
                    ForEach(groups, id: \.0.id) { cat, list in
                        sectionCard(cat, list)
                    }
                    if !permanent.isEmpty {
                        Card(padding: DS.s4) {
                            Toggle(isOn: $acknowledgePermanent) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("I understand these \(permanent.count) item\(permanent.count == 1 ? "" : "s") cannot be recovered")
                                        .font(DS.body().weight(.semibold)).foregroundStyle(DS.text)
                                    Text("There is no undo and no backup. Check anything you might still want before continuing.")
                                        .font(DS.caption()).foregroundStyle(DS.textDim)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .padding(DS.s5)
            }

            Divider()

            HStack {
                Button("Cancel") { isPresented = false }
                    .buttonStyle(SecondaryButton())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if !admin.isEmpty {
                    Label("macOS will ask for your password once",
                          systemImage: "lock.fill")
                        .font(DS.caption()).foregroundStyle(DS.textDim)
                }
                Button("Clean \(Bytes.fmt(totalBytes))") {
                    Task { await cleaner.run(items) }
                }
                .buttonStyle(PrimaryButton(tint: permanent.isEmpty ? DS.accent : DS.danger))
                .disabled(blocked)
                .help(blocked ? "Confirm the permanent deletions first" : "Begin cleaning")
            }
            .padding(DS.s5)
        }
    }

    private func sectionCard(_ cat: Category, _ list: [ScanItem]) -> some View {
        Card(padding: DS.s4) {
            VStack(alignment: .leading, spacing: DS.s3) {
                HStack(spacing: DS.s2) {
                    Image(systemName: cat.symbol)
                        .font(.system(size: 12)).foregroundStyle(cat.hue)
                    Text(cat.title).font(DS.body().weight(.semibold)).foregroundStyle(DS.text)
                    TierBadge(tier: cat.tier)
                    Spacer()
                    Text(Bytes.fmt(list.reduce(0) { $0 + $1.bytes }))
                        .font(DS.mono(13, .semibold)).foregroundStyle(DS.text)
                }
                Text(cat.restoreHint).font(DS.caption()).foregroundStyle(DS.textDim)
                Divider().opacity(0.5)
                ForEach(list) { i in
                    HStack(spacing: DS.s2) {
                        Image(systemName: i.tier.symbol)
                            .font(.system(size: 9)).foregroundStyle(i.tier.tint)
                        Text(i.name).font(DS.caption()).foregroundStyle(DS.text)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if i.bytes > 0 {
                            Text(Bytes.fmt(i.bytes)).font(DS.mono(11, .medium))
                                .foregroundStyle(DS.textDim)
                        }
                    }
                }
            }
        }
    }

    private func group(_ tier: SafetyTier, _ list: [ScanItem]) -> some View {
        Card(padding: DS.s4) {
            VStack(alignment: .leading, spacing: DS.s3) {
                HStack(spacing: DS.s2) {
                    TierBadge(tier: tier)
                    Text(tier.blurb).font(DS.caption()).foregroundStyle(DS.textDim)
                    Spacer()
                    Text(Bytes.fmt(list.reduce(0) { $0 + $1.bytes }))
                        .font(DS.mono(13, .semibold)).foregroundStyle(DS.text)
                }
                ForEach(list) { i in
                    HStack(spacing: DS.s2) {
                        Image(systemName: tier.symbol)
                            .font(.system(size: 9)).foregroundStyle(tier.tint)
                        Text(i.name).font(DS.caption()).foregroundStyle(DS.text)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Bytes.fmt(i.bytes)).font(DS.mono(11, .medium))
                            .foregroundStyle(DS.textDim)
                    }
                }
            }
        }
    }

    // MARK: Running

    private var running: some View {
        VStack(spacing: DS.s4) {
            Spacer()
            ProgressView(value: cleaner.progress)
                .progressViewStyle(.linear)
                .frame(width: 320)
            Text(cleaner.currentStep.isEmpty ? "Working…" : cleaner.currentStep)
                .font(DS.body()).foregroundStyle(DS.text)
                .lineLimit(1).truncationMode(.middle).frame(maxWidth: 420)
            Text("\(Int(cleaner.progress * 100))%")
                .font(DS.mono(12, .medium)).foregroundStyle(DS.textDim)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Results

    private var results: some View {
        VStack(spacing: 0) {
            VStack(spacing: DS.s3) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44)).foregroundStyle(DS.safe)
                Text(Bytes.fmt(cleaner.freedBytes))
                    .font(DS.mono(34, .bold)).foregroundStyle(DS.text)
                Text("reclaimed").font(DS.body()).foregroundStyle(DS.textDim)
            }
            .padding(.top, DS.s7).padding(.bottom, DS.s5)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DS.s2) {
                    ForEach(cleaner.outcomes) { o in
                        HStack(spacing: DS.s2) {
                            Image(systemName: o.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(o.ok ? DS.safe : DS.danger)
                            Text(o.name).font(DS.caption()).foregroundStyle(DS.text)
                                .lineLimit(1).truncationMode(.middle)
                            if let m = o.message {
                                Text(m).font(DS.caption()).foregroundStyle(DS.danger)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Text(Bytes.fmt(o.bytes)).font(DS.mono(11, .medium))
                                .foregroundStyle(DS.textDim)
                        }
                    }
                }
                .padding(DS.s5)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    isPresented = false
                    Task { await engine.scan() }
                }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
            .padding(DS.s5)
        }
    }
}
