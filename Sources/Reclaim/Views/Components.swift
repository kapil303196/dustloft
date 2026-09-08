import SwiftUI

// MARK: - Card

struct Card<Content: View>: View {
    var padding: CGFloat = DS.s5
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .background(DS.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.rLg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.rLg, style: .continuous)
                    .strokeBorder(DS.border, lineWidth: 1)
            )
    }
}

// MARK: - Badges

struct TierBadge: View {
    let tier: SafetyTier
    var compact = false
    var body: some View {
        HStack(spacing: DS.s1) {
            Image(systemName: tier.symbol).font(.system(size: 9, weight: .bold))
            if !compact { Text(tier.title).font(DS.caption().weight(.semibold)) }
        }
        .foregroundStyle(tier.tint)
        .padding(.horizontal, compact ? DS.s1 + 2 : DS.s2)
        .padding(.vertical, 3)
        .background(tier.soft, in: Capsule())
        .accessibilityLabel("Safety: \(tier.title)")
    }
}

struct SafetyBadge: View {
    let text: String
    let symbol: String
    let tint: Color
    var body: some View {
        HStack(spacing: DS.s1) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(text).font(DS.caption().weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, DS.s2)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: Capsule())
    }
}

// MARK: - Free space meter

struct StorageMeter: View {
    let volume: VolumeInfo
    let reclaimable: Int64
    let selected: Int64

    private var usedFrac: Double { volume.usedFraction }
    private var selFrac: Double {
        volume.total > 0 ? min(Double(selected) / Double(volume.total), usedFrac) : 0
    }

    private var pressure: Color {
        switch usedFrac {
        case ..<0.75: return DS.safe
        case ..<0.90: return DS.warn
        default:      return DS.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Bytes.fmt(volume.free))
                        .font(DS.mono(30, .bold))
                        .foregroundStyle(DS.text)
                        .contentTransition(.numericText())
                    Text("free of \(Bytes.fmt(volume.total))")
                        .font(DS.body()).foregroundStyle(DS.textDim)
                }
                Spacer()
                if selected > 0 {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("+ " + Bytes.fmt(selected))
                            .font(DS.mono(20, .bold)).foregroundStyle(DS.accent)
                            .contentTransition(.numericText())
                        Text("selected to reclaim")
                            .font(DS.caption()).foregroundStyle(DS.textDim)
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
                }
            }

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.surfaceAlt)
                    // Space in use
                    Capsule().fill(pressure.opacity(0.55))
                        .frame(width: max(0, w * usedFrac))
                    // The slice the current selection would give back
                    if selFrac > 0 {
                        Capsule().fill(DS.accent)
                            .frame(width: max(0, w * selFrac))
                            .offset(x: max(0, w * (usedFrac - selFrac)))
                    }
                }
            }
            .frame(height: 10)
            .animation(DS.spring, value: selFrac)
            .animation(DS.spring, value: usedFrac)

            HStack(spacing: DS.s4) {
                LegendDot(color: pressure.opacity(0.55), label: "\(Int(usedFrac * 100))% in use")
                if selected > 0 { LegendDot(color: DS.accent, label: "would be freed") }
                Spacer()
                if reclaimable > 0 {
                    Text("\(Bytes.fmt(reclaimable)) reclaimable found")
                        .font(DS.caption()).foregroundStyle(DS.textDim)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(Bytes.fmt(volume.free)) free of \(Bytes.fmt(volume.total)), \(Int(usedFrac * 100)) percent in use")
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: DS.s1 + 2) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(DS.caption()).foregroundStyle(DS.textDim)
        }
    }
}

// MARK: - Composition bar: what the found bytes are made of

struct CompositionBar: View {
    let slices: [(Category, Int64)]
    var total: Int64 { slices.reduce(0) { $0 + $1.1 } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.s3) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(slices, id: \.0.id) { cat, bytes in
                        let frac = total > 0 ? Double(bytes) / Double(total) : 0
                        RoundedRectangle(cornerRadius: 3)
                            .fill(cat.hue)
                            .frame(width: max(3, geo.size.width * frac))
                            .help("\(cat.title) — \(Bytes.fmt(bytes))")
                            .accessibilityLabel("\(cat.title), \(Bytes.fmt(bytes))")
                    }
                }
            }
            .frame(height: 8)

            // Legend carries an icon as well as a colour, so colour is never the only cue.
            FlowRow(spacing: DS.s3) {
                ForEach(slices.prefix(6), id: \.0.id) { cat, bytes in
                    HStack(spacing: DS.s1 + 2) {
                        Image(systemName: cat.symbol)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(cat.hue)
                        Text(cat.title).font(DS.caption()).foregroundStyle(DS.textDim)
                        Text(Bytes.fmt(bytes)).font(DS.mono(11, .semibold)).foregroundStyle(DS.text)
                    }
                }
            }
        }
    }
}

/// Minimal wrapping stack — legends must not clip on narrow windows.
struct FlowRow<Content: View>: View {
    var spacing: CGFloat = DS.s2
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content }
            VStack(alignment: .leading, spacing: DS.s1 + 2) { content }
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var action: (label: String, run: () -> Void)? = nil

    var body: some View {
        VStack(spacing: DS.s3) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(DS.textFaint)
            Text(title).font(DS.heading()).foregroundStyle(DS.text)
            Text(message)
                .font(DS.body()).foregroundStyle(DS.textDim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(PrimaryButton())
                    .padding(.top, DS.s1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.s6)
    }
}

// MARK: - Buttons

struct PrimaryButton: ButtonStyle {
    var tint: Color = DS.accent
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.body().weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, DS.s4)
            .padding(.vertical, DS.s2 + 1)
            .background(tint.opacity(enabled ? (configuration.isPressed ? 0.82 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: DS.rMd, style: .continuous))
            // Opacity/scale only — never anything that reflows neighbouring content.
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(DS.quick, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}

struct SecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.body().weight(.medium))
            .foregroundStyle(enabled ? DS.text : DS.textFaint)
            .padding(.horizontal, DS.s4)
            .padding(.vertical, DS.s2 + 1)
            .background(
                RoundedRectangle(cornerRadius: DS.rMd, style: .continuous)
                    .fill(configuration.isPressed ? DS.surfaceAlt : DS.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.rMd, style: .continuous)
                    .strokeBorder(DS.border, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(DS.quick, value: configuration.isPressed)
            .contentShape(Rectangle())
    }
}
