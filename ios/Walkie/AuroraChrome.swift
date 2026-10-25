import SwiftUI
import UIKit

enum Aurora {
    static let ink = Color(red: 0.015, green: 0.02, blue: 0.045)
    static let teal = Color(red: 0.28, green: 0.92, blue: 0.78)
    static let green = Color(red: 0.35, green: 0.95, blue: 0.55)
    static let violet = Color(red: 0.58, green: 0.42, blue: 0.98)
}

enum ChannelCode {
    static func label(id: String, groups: [WalkieGroup]) -> String {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return "CH --" }
        return String(format: "CH %02d", index + 1)
    }
}

/// Generators stay prepared so the first click is not late.
@MainActor
enum WalkieHaptics {
    private static let press = UIImpactFeedbackGenerator(style: .heavy)
    private static let release = UIImpactFeedbackGenerator(style: .soft)
    private static let remoteStart = UINotificationFeedbackGenerator()
    private static let remoteStop = UIImpactFeedbackGenerator(style: .light)

    static func prepare() {
        press.prepare()
        release.prepare()
        remoteStart.prepare()
        remoteStop.prepare()
    }

    static func pressTalk() {
        press.impactOccurred()
        press.prepare()
        release.prepare()
    }

    static func releaseTalk() {
        release.impactOccurred(intensity: 0.65)
        release.prepare()
        press.prepare()
    }

    static func remoteStarted() {
        remoteStart.notificationOccurred(.success)
        remoteStart.prepare()
        remoteStop.prepare()
    }

    static func remoteStopped() {
        remoteStop.impactOccurred(intensity: 0.35)
        remoteStop.prepare()
    }
}

struct AuroraBackground: View {
    var live: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: live ? 1.0 / 30.0 : 1.0 / 12.0)) { timeline in
            AuroraField(time: timeline.date.timeIntervalSinceReferenceDate, live: live)
        }
        .ignoresSafeArea()
    }
}

private struct AuroraField: View {
    var time: TimeInterval
    var live: Bool

    var body: some View {
        ZStack {
            Aurora.ink
            AuroraBlob(time: time, live: live, color: Aurora.green, phase: 0.4, size: 320, slot: 0)
            AuroraBlob(time: time, live: live, color: Aurora.teal, phase: 2.1, size: 280, slot: 1)
            AuroraBlob(time: time, live: live, color: Aurora.violet, phase: 4.2, size: 300, slot: 2)
        }
    }
}

private struct AuroraBlob: View {
    var time: TimeInterval
    var live: Bool
    var color: Color
    var phase: Double
    var size: CGFloat
    var slot: Int

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .blur(radius: live ? 56 : 84)
            .opacity(live ? 0.78 : 0.36)
            .offset(x: driftX, y: driftY)
    }

    private var speed: Double {
        live ? 0.62 : 0.16
    }

    private var driftX: CGFloat {
        let spread = live ? 110.0 : 42.0
        return CGFloat(cos(time * speed + phase) * spread + Double(slot - 1) * 16)
    }

    private var driftY: CGFloat {
        let spread = live ? 86.0 : 28.0
        return CGFloat(sin(time * speed * 0.75 + phase) * spread)
    }

    private var diameter: CGFloat {
        live ? size * 1.22 : size
    }
}

struct AuroraRings: View {
    var pulsing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: pulsing ? 1.0 / 30.0 : 1)) { timeline in
            AuroraRingStack(time: timeline.date.timeIntervalSinceReferenceDate, pulsing: pulsing)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AuroraRingStack: View {
    var time: TimeInterval
    var pulsing: Bool

    var body: some View {
        ZStack {
            AuroraRing(time: time, pulsing: pulsing, index: 0, color: Aurora.teal)
            AuroraRing(time: time, pulsing: pulsing, index: 1, color: Aurora.green)
            AuroraRing(time: time, pulsing: pulsing, index: 2, color: Aurora.violet)
        }
    }
}

private struct AuroraRing: View {
    var time: TimeInterval
    var pulsing: Bool
    var index: Int
    var color: Color

    var body: some View {
        Circle()
            .stroke(color.opacity(0.12 + 0.5 * wave), lineWidth: 2)
            .frame(width: 180, height: 180)
            .scaleEffect(scale)
    }

    private var wave: Double {
        if !pulsing { return 0 }
        return 0.5 + 0.5 * sin(time * 1.7 + Double(index) * 0.85)
    }

    private var scale: CGFloat {
        let base = 1.05 + CGFloat(index) * 0.16
        if !pulsing { return base }
        return base + CGFloat(wave) * 0.1
    }
}

struct LedDot: View {
    var on: Bool

    var body: some View {
        Circle()
            .fill(on ? Aurora.green : Color.white.opacity(0.22))
            .frame(width: 7, height: 7)
            .shadow(color: on ? Aurora.green.opacity(0.95) : .clear, radius: on ? 5 : 0)
            .accessibilityHidden(true)
    }
}

struct TuningReadout: View {
    var code: String
    var name: String
    var mode: String
    var action: () -> Void
    @State private var settling = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(code)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                ModeLabel(mode: mode)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.8))
            .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
        .offset(x: settling ? 10 : 0)
        .opacity(settling ? 0.4 : 1)
        .animation(.easeOut(duration: 0.28), value: settling)
        .onChange(of: code) { _, _ in retune() }
        .accessibilityHint("Åpner gruppene")
    }

    private func retune() {
        settling = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            settling = false
        }
    }
}

struct ModeLabel: View {
    var mode: String

    var body: some View {
        if mode.isEmpty {
            Text(" ")
                .font(.system(.caption2, design: .monospaced))
                .accessibilityHidden(true)
        } else {
            Text(mode)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .foregroundStyle(mode == "TX" ? Aurora.teal : Aurora.violet)
                .accessibilityLabel(mode == "TX" ? "Sender" : "Mottar")
        }
    }
}

struct ChannelTitle: View {
    var code: String
    var name: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(code)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(.headline, design: .monospaced))
                .lineLimit(1)
        }
    }
}

extension View {
    func auroraCard() -> some View {
        self
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.8)
            )
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    func auroraField() -> some View {
        self
            .textFieldStyle(.plain)
            .tint(Aurora.teal)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.8)
            )
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
