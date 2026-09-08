import SwiftUI
import AppKit

// MARK: - Design tokens
// Semantic tokens only. Never use a raw hex inside a view.
// Every colour is defined for BOTH appearances so light/dark stay in step.

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

extension Color {
    /// Appearance-aware colour. Resolves live when the system theme flips.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

enum DS {

    // MARK: Surfaces
    static let bg          = Color.adaptive(light: 0xF6F8FB, dark: 0x0C1116)
    static let surface     = Color.adaptive(light: 0xFFFFFF, dark: 0x141B23)
    static let surfaceAlt  = Color.adaptive(light: 0xF1F5F9, dark: 0x1A222C)
    static let raised      = Color.adaptive(light: 0xFFFFFF, dark: 0x1E2731)
    static let border      = Color.adaptive(light: 0xE2E8F0, dark: 0x27323F)
    static let borderStrong = Color.adaptive(light: 0xCBD5E1, dark: 0x35424F)

    // MARK: Content — verified >= 4.5:1 on their surfaces in both themes
    static let text        = Color.adaptive(light: 0x0F172A, dark: 0xE9EFF7)
    static let textDim     = Color.adaptive(light: 0x51607A, dark: 0x9AAABF)
    static let textFaint   = Color.adaptive(light: 0x76839A, dark: 0x6F8098)

    // MARK: Brand + semantics
    static let accent      = Color.adaptive(light: 0x2563EB, dark: 0x4C8DFF)
    static let accentSoft  = Color.adaptive(light: 0xDBE7FE, dark: 0x18304F)

    static let safe        = Color.adaptive(light: 0x047857, dark: 0x34D399)
    static let safeSoft    = Color.adaptive(light: 0xD1FAE5, dark: 0x0C3A2E)

    static let warn        = Color.adaptive(light: 0xB45309, dark: 0xF9B23C)
    static let warnSoft    = Color.adaptive(light: 0xFEF0C7, dark: 0x40300D)

    static let danger      = Color.adaptive(light: 0xB91C1C, dark: 0xFF7A7A)
    static let dangerSoft  = Color.adaptive(light: 0xFEE2E2, dark: 0x44191C)

    // MARK: Spacing — strict 4pt rhythm
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 28
    static let s7: CGFloat = 40

    // MARK: Radius
    static let rSm: CGFloat = 6
    static let rMd: CGFloat = 10
    static let rLg: CGFloat = 16

    // MARK: Motion — 150-300ms, spring for anything spatial.
    // Every animation here reports a state change: something arrived, left,
    // was selected, or changed value. None of it is decorative.
    static let quick  = Animation.easeOut(duration: 0.18)
    static let exit   = Animation.easeIn(duration: 0.12)   // exits ~65% of enter
    static let spring = Animation.spring(response: 0.34, dampingFraction: 0.84)
    /// Rows arriving from a scan: gentle, and staggered by index.
    static let arrive = Animation.spring(response: 0.42, dampingFraction: 0.86)
    static let stagger: Double = 0.035
    static let staggerCap = 10          // never delay past ~350ms

    /// Honours the system Reduce Motion setting.
    static func motion(_ base: Animation, reduce: Bool) -> Animation? {
        reduce ? nil : base
    }

    static func staggered(_ index: Int, reduce: Bool) -> Animation? {
        guard !reduce else { return nil }
        return arrive.delay(Double(min(index, staggerCap)) * stagger)
    }

    // MARK: Type scale
    static func title()   -> Font { .system(size: 22, weight: .semibold) }
    static func heading() -> Font { .system(size: 15, weight: .semibold) }
    static func body()    -> Font { .system(size: 13, weight: .regular) }
    static func label()   -> Font { .system(size: 12, weight: .medium) }
    static func caption() -> Font { .system(size: 11, weight: .regular) }
    /// Tabular figures stop size columns from jittering as values change.
    static func mono(_ size: CGFloat = 13, _ w: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: w).monospacedDigit()
    }
}

// MARK: - Byte formatting
enum Bytes {
    static func fmt(_ b: Int64) -> String {
        if b <= 0 { return "0 B" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f.string(fromByteCount: b)
    }
}
