import SwiftUI

/// What the "Reclaimable" figure is actually made of. Reached by clicking the
/// figure itself, which reads as tappable and previously did nothing.
struct SummarySheet: View {
    @ObservedObject var engine: ScanEngine
    @Binding var isPresented: Bool

    private var rows: [(Category, [ScanItem])] {
        Category.all.compactMap { cat in
            let list = (engine.items[cat.id] ?? []).filter { !$0.isAdvisory }
            return list.isEmpty ? nil : (cat, list)
        }
        .sorted { a, b in
            a.1.reduce(0) { $0 + $1.bytes } > b.1.reduce(0) { $0 + $1.bytes }
        }
    }

    private var safeTotal: Int64 { engine.totalSafe }
    private var pickedTotal: Int64 { engine.totalSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DS.s2) {
                Text("What can be reclaimed").font(DS.title()).foregroundStyle(DS.text)
                Text("\(Bytes.fmt(engine.totalFound)) found across \(rows.count) categor\(rows.count == 1 ? "y" : "ies") · \(Bytes.fmt(pickedTotal)) selected so far")
                    .font(DS.body()).foregroundStyle(DS.textDim)
            }
            .padding(DS.s5)

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.0.id) { idx, pair in
                        let (cat, list) = pair
                        let bytes = list.reduce(Int64(0)) { $0 + $1.bytes }
                        let picked = list.filter { $0.selected }.count
                        HStack(spacing: DS.s3) {
                            Image(systemName: cat.symbol)
                                .font(.system(size: 13)).foregroundStyle(cat.hue)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(cat.title).font(DS.body().weight(.medium)).foregroundStyle(DS.text)
                                Text(picked > 0 ? "\(list.count) items · \(picked) selected"
                                                : "\(list.count) items")
                                    .font(DS.caption())
                                    .foregroundStyle(picked > 0 ? DS.accent : DS.textDim)
                            }
                            Spacer()
                            TierBadge(tier: cat.tier)
                            Text(Bytes.fmt(bytes))
                                .font(DS.mono(13, .semibold)).foregroundStyle(DS.text)
                                .frame(minWidth: 82, alignment: .trailing)
                        }
                        .padding(.vertical, DS.s3)
                        if idx < rows.count - 1 { Divider().opacity(0.5).padding(.leading, 34) }
                    }
                }
                .padding(.horizontal, DS.s5)
                .padding(.vertical, DS.s2)
            }

            Divider()

            HStack(spacing: DS.s3) {
                Label("\(Bytes.fmt(safeTotal)) of this rebuilds itself and is safe to clear",
                      systemImage: "checkmark.shield.fill")
                    .font(DS.caption()).foregroundStyle(DS.safe)
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(PrimaryButton())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.s5)
        }
        .frame(width: 640, height: 560)
        .background(DS.bg)
    }
}
