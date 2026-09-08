import SwiftUI

struct CategoryDetailView: View {
    let category: Category
    @ObservedObject var engine: ScanEngine
    /// Opens the review sheet scoped to this section only.
    var reviewSection: () -> Void = {}

    private var items: [ScanItem] { engine.items[category.id] ?? [] }
    private var selectable: [ScanItem] { items.filter { !$0.isAdvisory } }
    private var pickedHere: [ScanItem] { items.filter { $0.selected } }
    private var pickedBytes: Int64 { pickedHere.reduce(0) { $0 + $1.bytes } }

    private var allPicked: Bool {
        !selectable.isEmpty && selectable.allSatisfy { $0.selected }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.s4) {
                header

                if items.isEmpty {
                    Card {
                        EmptyStateView(symbol: "checkmark.circle",
                                       title: "Nothing found here",
                                       message: "This category is already clean.")
                            .frame(height: 180)
                    }
                } else {
                    Card(padding: DS.s3) {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                ItemRow(item: item, category: category) { on in
                                    withAnimation(DS.quick) { engine.setSelection(item.id, on) }
                                }
                                if item.id != items.last?.id {
                                    Divider().padding(.leading, DS.s6)
                                }
                            }
                        }
                    }
                }
            }
            .padding(DS.s5)
        }
    }

    private var header: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.s3) {
                HStack(spacing: DS.s3) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DS.rMd, style: .continuous)
                            .fill(category.hue.opacity(0.16))
                        Image(systemName: category.symbol)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(category.hue)
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.title).font(DS.title()).foregroundStyle(DS.text)
                        Text(category.blurb).font(DS.body()).foregroundStyle(DS.textDim)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Bytes.fmt(selectable.reduce(0) { $0 + $1.bytes }))
                            .font(DS.mono(19, .bold)).foregroundStyle(DS.text)
                        Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                            .font(DS.caption()).foregroundStyle(DS.textDim)
                    }
                }

                HStack(spacing: DS.s2) {
                    TierBadge(tier: category.tier)
                    Text(category.tier.blurb).font(DS.caption()).foregroundStyle(DS.textDim)
                    Spacer()
                    if !selectable.isEmpty {
                        Button(allPicked ? "Deselect all" : "Select all \(selectable.count)") {
                            withAnimation(DS.quick) {
                                engine.selectAll(in: category.id, !allPicked)
                            }
                        }
                        .buttonStyle(SecondaryButton())
                        .help(category.tier == .permanent
                              ? "Selects all \(selectable.count) items. You still have to confirm the permanent deletion before anything is removed."
                              : "Toggle every item in this category")
                    }
                }

                HStack(spacing: DS.s1 + 2) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10)).foregroundStyle(DS.textFaint)
                    Text("Restore by: \(category.restoreHint)")
                        .font(DS.caption()).foregroundStyle(DS.textDim)
                    Spacer()
                    if !pickedHere.isEmpty {
                        Button("Clean this section · \(Bytes.fmt(pickedBytes))") {
                            reviewSection()
                        }
                        .buttonStyle(PrimaryButton(tint: category.tier == .permanent ? DS.danger : DS.accent))
                        .help("Review and clean only the \(pickedHere.count) selected item(s) in \(category.title)")
                    }
                }
            }
        }
    }
}

// MARK: - Item row

struct ItemRow: View {
    let item: ScanItem
    let category: Category
    let toggle: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: DS.s3) {
            if item.isAdvisory {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 14)).foregroundStyle(DS.textFaint)
                    .frame(width: 20, height: 20)
            } else {
                Toggle("", isOn: Binding(get: { item.selected }, set: { toggle($0) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .frame(width: 20, height: 20)
                    .accessibilityLabel("Select \(item.name)")
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.s2) {
                    Text(item.name)
                        .font(DS.body().weight(.medium))
                        .foregroundStyle(DS.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.tier == .permanent { TierBadge(tier: .permanent, compact: true) }
                    if item.tier == .admin { TierBadge(tier: .admin, compact: true) }
                }

                if let g = item.git, let badge = g.badge {
                    SafetyBadge(text: badge.0, symbol: badge.1, tint: badge.2)
                }

                if let d = item.detail {
                    Text(d).font(DS.caption()).foregroundStyle(DS.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if case .advisory(let cmd) = item.action {
                    HStack(spacing: DS.s2) {
                        Text(cmd)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DS.text)
                            .padding(.horizontal, DS.s2).padding(.vertical, DS.s1)
                            .background(DS.surfaceAlt, in: RoundedRectangle(cornerRadius: DS.rSm))
                            .textSelection(.enabled)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy command")
                    }
                    .padding(.top, 2)
                }

                Text(item.path)
                    .font(DS.caption())
                    .foregroundStyle(DS.textFaint)
                    .lineLimit(1).truncationMode(.middle)
                    .help(item.path)
            }

            Spacer(minLength: DS.s3)

            if item.bytes > 0 {
                Text(Bytes.fmt(item.bytes))
                    .font(DS.mono(13, .semibold))
                    .foregroundStyle(item.selected ? DS.accent : DS.text)
                    .frame(minWidth: 78, alignment: .trailing)
            }

            Button {
                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .opacity(hovering && FileManager.default.fileExists(atPath: item.path) ? 1 : 0)
            .help("Reveal in Finder")
        }
        .padding(.vertical, DS.s2 + 2)
        .padding(.horizontal, DS.s2)
        .background(
            RoundedRectangle(cornerRadius: DS.rSm)
                .fill(hovering ? DS.surfaceAlt.opacity(0.6) : Color.clear)
        )
        .onHover { h in withAnimation(DS.quick) { hovering = h } }
    }
}
