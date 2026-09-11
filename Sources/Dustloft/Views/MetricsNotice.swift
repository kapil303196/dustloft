import SwiftUI
import AppKit

/// Shown once, on the Overview, until it is dismissed.
///
/// It leads with the payload rather than a reassurance, because a claim that
/// something is anonymous is worth nothing next to the three fields themselves.
/// Turning it off is a button on this card, not a preference two menus away.
struct MetricsNotice: View {
    @ObservedObject var metrics: Metrics

    var body: some View {
        Card(padding: DS.s4) {
            HStack(alignment: .top, spacing: DS.s3) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 16))
                    .foregroundStyle(DS.accent)

                VStack(alignment: .leading, spacing: DS.s3) {
                    VStack(alignment: .leading, spacing: DS.s1) {
                        Text("Dustloft counts installs and space reclaimed")
                            .font(DS.body().weight(.semibold))
                            .foregroundStyle(DS.text)
                        Text("So there is some idea of how many Macs this runs on and whether it has actually given anyone their disk back. This is the entire message, sent about once a day:")
                            .font(DS.caption())
                            .foregroundStyle(DS.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    MetricsPayloadSample(cleaned: metrics.lifetimeCleaned)

                    Text("No name, no email, no account, no file names, no paths. The identifier is random and belongs to this copy of the app, not to you. Your IP address is used only to rate limit — a salted hash of it becomes a counter that expires after a minute, and the address itself is never written down or attached to anything.")
                        .font(DS.caption())
                        .foregroundStyle(DS.textDim)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: DS.s2) {
                        Button("Turn it off") {
                            metrics.optedOut = true
                            metrics.noticeSeen = true
                        }
                        .buttonStyle(SecondaryButton())

                        Button("Keep it on") { metrics.noticeSeen = true }
                            .buttonStyle(PrimaryButton())

                        Button("Read the privacy note") {
                            if let url = URL(string: "https://dustloft.com/privacy") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(DS.caption())

                        Spacer()
                    }
                }
                Spacer(minLength: 0)
            }
        }
        // Nothing is sent until this has happened at least once.
        .onAppear { metrics.markNoticeShown() }
    }
}

/// The literal payload, with this Mac's real numbers in it.
struct MetricsPayloadSample: View {
    let cleaned: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            field("id", "\"a random UUID, generated here\"")
            field("cleaned", "\(cleaned)")
            field("version", "\"\(Metrics.appVersion.isEmpty ? "unknown" : Metrics.appVersion)\"")
        }
        .padding(.vertical, DS.s2)
        .padding(.horizontal, DS.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.rSm, style: .continuous).fill(DS.surfaceAlt)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("The message sent is an identifier, \(cleaned) bytes cleaned, and the version.")
    }

    private func field(_ key: String, _ value: String) -> some View {
        HStack(spacing: DS.s1) {
            Text("\(key):").font(DS.mono(11, .semibold)).foregroundStyle(DS.textDim)
            Text(value).font(DS.mono(11, .regular)).foregroundStyle(DS.text)
        }
    }
}

/// The permanent switch, so the decision is never one the notice took for good.
struct MetricsFooterControl: View {
    @ObservedObject var metrics: Metrics

    var body: some View {
        if Metrics.suppressedByEnvironment {
            Text("· anonymous counting off (DUSTLOFT_NO_METRICS)")
                .font(DS.caption())
                .foregroundStyle(DS.textFaint)
                .help("Disabled by the environment. Unset DUSTLOFT_NO_METRICS to allow it.")
        } else {
            Button(metrics.optedOut ? "Anonymous counting: off" : "Anonymous counting: on") {
                metrics.optedOut.toggle()
                metrics.noticeSeen = true
            }
            .buttonStyle(.link)
            .font(DS.caption())
            .help(metrics.optedOut
                  ? "Nothing is being sent. Click to send an anonymous install count and total reclaimed."
                  : "Sends only a random identifier, the total bytes reclaimed, and the version. Click to stop.")
        }
    }
}
