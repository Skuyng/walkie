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

/// Strong generators, created on the main thread with the session.
/// `playAndRecord` silences haptics unless the audio session allows them.
final class WalkieHaptics {
    private let press: UIImpactFeedbackGenerator
    private let release: UIImpactFeedbackGenerator
    private let remoteStart: UINotificationFeedbackGenerator
    private let remoteStop: UIImpactFeedbackGenerator

    init() {
        dispatchPrecondition(condition: .onQueue(.main))
        press = UIImpactFeedbackGenerator(style: .heavy)
        release = UIImpactFeedbackGenerator(style: .soft)
        remoteStart = UINotificationFeedbackGenerator()
        remoteStop = UIImpactFeedbackGenerator(style: .light)
        prepareNow()
    }

    func prepare() {
        onMain { self.prepareNow() }
    }

    func pressTalk() {
        onMain { self.firePress() }
    }

    func releaseTalk() {
        onMain { self.fireRelease() }
    }

    func remoteStarted() {
        onMain { self.fireRemoteStart() }
    }

    func remoteStopped() {
        onMain { self.fireRemoteStop() }
    }

    /// Volume-up and the on-screen press both land here. Fire immediately on
    /// the main thread; hop if a caller is not already there.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    private func prepareNow() {
        press.prepare()
        release.prepare()
        remoteStart.prepare()
        remoteStop.prepare()
    }

    private func firePress() {
        press.impactOccurred()
        press.prepare()
        release.prepare()
    }

    private func fireRelease() {
        release.impactOccurred(intensity: 0.65)
        release.prepare()
        press.prepare()
    }

    private func fireRemoteStart() {
        remoteStart.notificationOccurred(.success)
        remoteStart.prepare()
        remoteStop.prepare()
    }

    private func fireRemoteStop() {
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

/// Thread-safe raw loudness. The audio queue writes; the main pump reads.
final class LevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var mic: Float = 0
    private var remote: Float = 0
    private var micAt = Date.distantPast
    private var remoteAt = Date.distantPast

    func setMic(_ value: Float) {
        lock.lock()
        mic = value
        micAt = Date()
        lock.unlock()
    }

    func setRemote(_ value: Float) {
        lock.lock()
        remote = value
        remoteAt = Date()
        lock.unlock()
    }

    func sample() -> (mic: Float, remote: Float) {
        lock.lock()
        let now = Date()
        let micValue = now.timeIntervalSince(micAt) > 0.12 ? Float(0) : mic
        let remoteValue = now.timeIntervalSince(remoteAt) > 0.22 ? Float(0) : remote
        lock.unlock()
        return (micValue, remoteValue)
    }
}

/// Smoothed levels, published on the main thread at about 45 fps while audio is live.
@MainActor
final class AudioLevels: ObservableObject {
    @Published private(set) var mic: Float = 0
    @Published private(set) var remote: Float = 0
    let meter = LevelMeter()
    private var task: Task<Void, Never>?
    private var micState: Float = 0
    private var remoteState: Float = 0

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let sample = self.meter.sample()
                let micNext = Self.follow(self.micState, sample.mic)
                let remoteNext = Self.follow(self.remoteState, sample.remote)
                self.micState = micNext
                self.remoteState = remoteNext
                self.assignMic(micNext)
                self.assignRemote(remoteNext)
                let live = micNext > 0.02 || remoteNext > 0.02 || sample.mic > 0.02 || sample.remote > 0.02
                try? await Task.sleep(for: .milliseconds(live ? 22 : 160))
            }
        }
    }

    private func assignMic(_ value: Float) {
        let shown = value < 0.015 ? Float(0) : value
        if abs(shown - mic) < 0.01 { return }
        mic = shown
    }

    private func assignRemote(_ value: Float) {
        let shown = value < 0.015 ? Float(0) : value
        if abs(shown - remote) < 0.01 { return }
        remote = shown
    }

    private static func follow(_ current: Float, _ target: Float) -> Float {
        let rate: Float = target > current ? 0.62 : 0.34
        return current + (target - current) * rate
    }
}

/// Liquid fill clipped by the caller. Quiet while the mic is open and silent; hidden when idle.
struct TalkLevelFill: View {
    @ObservedObject var levels: AudioLevels
    var transmitting: Bool
    var receiving: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
            TalkLevelCanvas(
                time: timeline.date.timeIntervalSinceReferenceDate,
                mic: CGFloat(levels.mic),
                remote: CGFloat(levels.remote),
                transmitting: transmitting,
                receiving: receiving
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var frameInterval: Double {
        (transmitting || receiving) ? 1.0 / 45.0 : 1
    }
}

private struct TalkLevelCanvas: View {
    var time: TimeInterval
    var mic: CGFloat
    var remote: CGFloat
    var transmitting: Bool
    var receiving: Bool

    var body: some View {
        Canvas { context, size in
            TalkLevelDraw.draw(
                context: &context,
                size: size,
                time: time,
                mic: mic,
                remote: remote,
                transmitting: transmitting,
                receiving: receiving
            )
        }
    }
}

private enum TalkLevelDraw {
    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        mic: CGFloat,
        remote: CGFloat,
        transmitting: Bool,
        receiving: Bool
    ) {
        guard transmitting || receiving, size.width > 1, size.height > 1 else { return }
        let level = min(1, max(0, transmitting ? mic : remote))
        let rise = transmitting ? (0.16 + level * 0.74) : (0.10 + level * 0.38)
        let glow = transmitting ? (0.20 + level * 0.72) : (0.10 + level * 0.30)
        let speed = transmitting ? 1.0 : 0.55
        let energy = 0.03 + level * (transmitting ? 0.10 : 0.05)
        context.clip(to: Path(ellipseIn: CGRect(origin: .zero, size: size)))
        let layers = bands(transmitting: transmitting)
        for (index, band) in layers.enumerated() {
            let path = wavePath(
                size: size,
                time: time * speed,
                rise: rise - CGFloat(index) * 0.04,
                energy: energy,
                frequency: band.frequency,
                phase: band.phase
            )
            context.fill(path, with: .color(band.color.opacity(glow * band.gain)))
        }
    }

    private static func bands(transmitting: Bool) -> [(color: Color, frequency: Double, phase: Double, gain: Double)] {
        if transmitting {
            return [
                (Aurora.violet, 1.15, 0.4, 0.55),
                (Aurora.teal, 1.75, 1.8, 0.82),
                (Aurora.green, 2.3, 3.0, 0.95)
            ]
        }
        return [
            (Aurora.violet, 0.75, 0.5, 0.65),
            (Aurora.teal, 1.1, 2.0, 0.7)
        ]
    }

    private static func wavePath(
        size: CGSize,
        time: TimeInterval,
        rise: CGFloat,
        energy: CGFloat,
        frequency: Double,
        phase: Double
    ) -> Path {
        var path = Path()
        let surface = size.height * (1 - max(0.05, rise))
        path.move(to: CGPoint(x: 0, y: size.height))
        let steps = 36
        for step in 0...steps {
            let t = CGFloat(step) / CGFloat(steps)
            let along = Double(t)
            let primary = sin(along * frequency * .pi * 2 + time * frequency + phase)
            let secondary = sin(along * (frequency + 1.4) * .pi * 2 - time * 0.65 + phase)
            let y = surface + CGFloat(primary * 0.72 + secondary * 0.28) * energy * size.height
            path.addLine(to: CGPoint(x: t * size.width, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
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
