import SwiftUI

struct ReviewSheet: View {
    @ObservedObject var engine: ScanEngine
    @ObservedObject var metrics: Metrics
    @Binding var isPresented: Bool
    /// nil reviews everything selected; a category id reviews just that section.
    var scope: String? = nil
    @StateObject private var cleaner = Cleaner()
    @State private var acknowledgePermanent = false
    /// Category id -> the rows that were selected when this sheet opened.
    /// Rendering from this fixed list means unticking every row in a section
    /// leaves the section on screen so it can be ticked back on.
    @State private var frozen: [(String, [UUID])] = []

    /// Rows needing confirmation that will not end up in the Trash.
    ///
    /// Asked of `effectiveAction`, not of the path, because there are two ways
    /// to miss the Trash and only one of them is about where the file is. An
    /// item already in the Trash has nowhere further to go — and so does one
    /// needing an administrator, because `Cleaner.run` partitions by action
    /// rather than tier, so an admin row never reaches the Trash routing at all
    /// and is unlinked by the batched root `rm`. Both are final; only the
    /// question "what will actually be run for this row" catches both.
    private var permanentDeletedOutright: [ScanItem] {
        permanent.filter {
            if case .trashPath = Cleaner.effectiveAction(for: $0) { return false }
            return true
        }
    }

    /// The promise has to match what is about to happen to the ticked rows.
    /// "They stay recoverable until you empty it" is true of a file on its way
    /// to the Trash and false of everything above, so it cannot simply be said
    /// to everyone.
    private var permanentWarning: String {
        let final = permanentDeletedOutright.count
        if final == 0 {
            return "Nothing rebuilds these, so they go to the Trash rather than being deleted outright. They stay recoverable until you empty it."
        }
        if final == permanent.count {
            return final == 1
                ? "This cannot be moved to the Trash — it is either already there or owned by the system. Ticking this deletes it for good, right now."
                : "These cannot be moved to the Trash — they are either already there or owned by the system. Ticking this deletes them for good, right now."
        }
        let recoverable = permanent.count - final
        return "Nothing rebuilds these. \(recoverable) of them go to the Trash and stay recoverable until you empty it. The other \(final) cannot — already there, or owned by the system — and \(final == 1 ? "that one is" : "those are") deleted for good, right now."
    }

    /// Selected rows, grouped by the section they came from and ordered with
    /// the riskiest sections first so nothing dangerous hides below the fold.
    /// Captures what was selected when the sheet appeared.
    private func freeze() {
        let keys = scope.map { [$0] } ?? Array(engine.items.keys)
        let built: [(String, [UUID])] = keys.compactMap { key in
            let picked = (engine.items[key] ?? []).filter { $0.selected }
            guard !picked.isEmpty else { return nil }
            return (key, picked.map { $0.id })
        }
        .sorted { a, b in
            func rank(_ t: SafetyTier) -> Int {
                switch t { case .permanent: return 0; case .admin: return 1; case .regenerable: return 2 }
            }
            let ca = Category.find(a.0), cb = Category.find(b.0)
            if rank(ca.tier) != rank(cb.tier) { return rank(ca.tier) < rank(cb.tier) }
            let sa = a.1.compactMap { engine.item($0)?.bytes }.reduce(0, +)
            let sb = b.1.compactMap { engine.item($0)?.bytes }.reduce(0, +)
            return sa > sb
        }
        frozen = built
    }

    private func rows(_ ids: [UUID]) -> [ScanItem] { ids.compactMap { engine.item($0) } }

    private var groups: [(Category, [ScanItem])] {
        frozen.map { (Category.find($0.0), rows($0.1)) }.filter { !$0.1.isEmpty }
    }

    /// Only what is still ticked gets cleaned.
    private var items: [ScanItem] { groups.flatMap { $0.1 }.filter { $0.selected } }
    private var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    private var offeredCount: Int { groups.reduce(0) { $0 + $1.1.count } }
    /// Everything that needs its own confirmation before this runs.
    ///
    /// Permanent tier, plus anything inside a Trash whatever its tier. A
    /// root-owned file in `~/.Trash` is classified `.admin` because removing it
    /// needs a password — but it is every bit as unrecoverable as the
    /// permanent-tier file next to it, and it was reaching the batched root
    /// `rm -rf` with no acknowledgement asked for at all.
    private var permanent: [ScanItem] {
        items.filter { item in
            if item.tier == .permanent { return true }
            return Cleaner.targetPath(of: item.action).map(Cleaner.isInsideTrash) ?? false
        }
    }
    private var admin: [ScanItem] { items.filter { $0.tier == .admin } }
    private var regen: [ScanItem] { items.filter { $0.tier == .regenerable } }
    private var blocked: Bool { !permanent.isEmpty && !acknowledgePermanent }

    var body: some View {
        VStack(spacing: 0) {
            if cleaner.finished       { results.transition(.opacity) }
            else if cleaner.isRunning { running.transition(.opacity) }
            else                      { review.transition(.opacity) }
        }
        .animation(DS.quick, value: cleaner.isRunning)
        .animation(DS.quick, value: cleaner.finished)
        // A progress bar does not need a 620x560 window.
        .onAppear { if frozen.isEmpty { freeze() } }
        // The tick is consent to one specific sentence. Change the ticked rows
        // and that sentence can change from "stays recoverable until you empty
        // the Trash" to "deleted for good, right now", so an acknowledgement
        // given to the first must not carry over to the second. Watched out
        // here rather than on the card itself, which is removed from the tree
        // when nothing permanent is ticked and would miss the change that
        // brings it back.
        .onChange(of: permanentWarning) { _ in acknowledgePermanent = false }
        .frame(width: cleaner.isRunning && !cleaner.finished ? 400 : 620,
               height: cleaner.isRunning && !cleaner.finished ? 168 : 560)
        .background(DS.bg)
    }

    // MARK: Review

    private var review: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.s2) {
                Text(scope == nil ? "Review before cleaning"
                                  : "Review \(Category.find(scope!).title)")
                    .font(DS.title()).foregroundStyle(DS.text)
                Text("\(items.count) of \(offeredCount) item\(offeredCount == 1 ? "" : "s") ticked · \(Bytes.fmt(totalBytes)) will be freed")
                    .font(DS.body()).foregroundStyle(DS.textDim)
                Text("Untick anything you want to keep. Only ticked items are removed.")
                    .font(DS.caption()).foregroundStyle(DS.textFaint)
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
                                    Text("I understand these \(permanent.count) item\(permanent.count == 1 ? "" : "s") are not regenerable")
                                        .font(DS.body().weight(.semibold)).foregroundStyle(DS.text)
                                    Text(permanentWarning)
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
                Button(items.isEmpty ? "Nothing ticked" : "Clean \(Bytes.fmt(totalBytes))") {
                    Task {
                        // Only on a run that actually happened. A second
                        // activation while one is in flight returns false with
                        // the earlier run's outcomes still in place, and would
                        // otherwise credit those bytes a second time.
                        guard await cleaner.run(items) else { return }
                        engine.removeCleaned(cleaner.cleanedIDs)
                        metrics.recordCleaned(cleaner.accountedBytes)
                    }
                }
                .buttonStyle(PrimaryButton(tint: permanent.isEmpty ? DS.accent : DS.danger))
                .disabled(blocked || items.isEmpty || cleaner.isRunning)
                .help(blocked ? "Confirm the permanent deletions first" : "Begin cleaning")
            }
            .padding(DS.s5)
        }
    }

    private func sectionCard(_ cat: Category, _ list: [ScanItem]) -> some View {
        let picked = list.filter { $0.selected }
        let allOn = picked.count == list.count
        return Card(padding: DS.s4) {
            VStack(alignment: .leading, spacing: DS.s3) {
                HStack(spacing: DS.s2) {
                    Image(systemName: cat.symbol)
                        .font(.system(size: 12)).foregroundStyle(cat.hue)
                    Text(cat.title).font(DS.body().weight(.semibold)).foregroundStyle(DS.text)
                    TierBadge(tier: cat.tier)
                    Spacer()
                    Button(allOn ? "Untick all" : "Tick all") {
                        withAnimation(DS.quick) {
                            for i in list { engine.setSelection(i.id, !allOn) }
                        }
                    }
                    .buttonStyle(.link)
                    .font(DS.caption())
                    Text(Bytes.fmt(picked.reduce(0) { $0 + $1.bytes }))
                        .font(DS.mono(13, .semibold))
                        .foregroundStyle(picked.isEmpty ? DS.textFaint : DS.text)
                        .frame(minWidth: 72, alignment: .trailing)
                }
                Text(cat.restoreHint).font(DS.caption()).foregroundStyle(DS.textDim)
                Divider().opacity(0.5)

                ForEach(list) { i in
                    HStack(spacing: DS.s2) {
                        Toggle("", isOn: Binding(
                            get: { i.selected },
                            set: { engine.setSelection(i.id, $0) }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .accessibilityLabel("Keep or remove \(i.name)")
                        Image(systemName: i.tier.symbol)
                            .font(.system(size: 9))
                            .foregroundStyle(i.selected ? i.tier.tint : DS.textFaint)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(i.name)
                                .font(DS.caption())
                                .foregroundStyle(i.selected ? DS.text : DS.textFaint)
                                .strikethrough(!i.selected, color: DS.textFaint)
                                .lineLimit(1).truncationMode(.middle)
                            Text(i.path)
                                .font(.system(size: 10))
                                .foregroundStyle(DS.textFaint)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if i.bytes > 0 {
                            Text(Bytes.fmt(i.bytes))
                                .font(DS.mono(11, .medium))
                                .foregroundStyle(i.selected ? DS.textDim : DS.textFaint)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { engine.setSelection(i.id, !i.selected) }
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
        VStack(alignment: .leading, spacing: DS.s3) {
            HStack(spacing: DS.s2) {
                ProgressView().controlSize(.small)
                Text("Cleaning…").font(DS.body().weight(.semibold)).foregroundStyle(DS.text)
                Spacer()
                Text("\(Int(cleaner.progress * 100))%")
                    .font(DS.mono(12, .semibold)).foregroundStyle(DS.textDim)
            }
            ProgressView(value: cleaner.progress).progressViewStyle(.linear)
            Text(cleaner.currentStep.isEmpty ? "Working…" : cleaner.currentStep)
                .font(DS.caption()).foregroundStyle(DS.textDim)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(DS.s5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
                // Trashed items still occupy the disk, so the volume delta
                // above does not count them. Saying so is the difference
                // between a clear result and an apparent bug.
                if cleaner.trashedBytes > 0 {
                    Text("\(Bytes.fmt(cleaner.trashedBytes)) moved to the Trash — still recoverable, and still using the space until you empty it")
                        .font(DS.caption()).foregroundStyle(DS.warn)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, DS.s5)
                }
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
                                // A message no longer implies a failure: a row
                                // that succeeded with nothing to do says "already
                                // gone", and painting that red next to a green
                                // tick reads as a contradiction.
                                Text(m).font(DS.caption())
                                    .foregroundStyle(o.ok ? DS.textDim : DS.danger)
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
                Button("Done") { isPresented = false }
                .buttonStyle(PrimaryButton())
                .keyboardShortcut(.defaultAction)
            }
            .padding(DS.s5)
        }
    }
}
