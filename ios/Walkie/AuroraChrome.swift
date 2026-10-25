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

/// Signed mic samples, oldest to newest. The audio queue writes; the button reads on main.
final class LevelMeter: @unchecked Sendable {
    static let length = 168
    private let lock = NSLock()
    private var mic = [Float](repeating: 0, count: LevelMeter.length)
    private var remote = [Float](repeating: 0, count: LevelMeter.length)
    private var micWrite = 0
    private var remoteWrite = 0
    private var remoteAt = Date.distantPast

    func appendMic(_ samples: [Float]) {
        lock.lock()
        append(samples, into: &mic, write: &micWrite)
        lock.unlock()
    }

    func appendRemote(_ samples: [Float]) {
        lock.lock()
        append(samples, into: &remote, write: &remoteWrite)
        remoteAt = Date()
        lock.unlock()
    }

    func clearMic() {
        lock.lock()
        mic = [Float](repeating: 0, count: LevelMeter.length)
        micWrite = 0
        lock.unlock()
    }

    func clearRemote() {
        lock.lock()
        remote = [Float](repeating: 0, count: LevelMeter.length)
        remoteWrite = 0
        remoteAt = .distantPast
        lock.unlock()
    }

    func history(remoteWanted: Bool) -> [Float] {
        lock.lock()
        let stale = remoteWanted && Date().timeIntervalSince(remoteAt) > 0.22
        let source = stale ? [Float](repeating: 0, count: LevelMeter.length) : (remoteWanted ? remote : mic)
        let write = remoteWanted ? remoteWrite : micWrite
        lock.unlock()
        if stale { return source }
        var ordered = [Float]()
        ordered.reserveCapacity(source.count)
        var index = write
        for _ in 0..<source.count {
            ordered.append(source[index])
            index += 1
            if index >= source.count { index = 0 }
        }
        return ordered
    }

    private func append(_ samples: [Float], into wave: inout [Float], write: inout Int) {
        for sample in samples {
            wave[write] = sample
            write += 1
            if write >= wave.count { write = 0 }
        }
    }
}

/// Owns the live sample history. The trace reads it on the main thread.
@MainActor
final class AudioLevels: ObservableObject {
    let meter = LevelMeter()
}

/// Live sample history across the middle of the button. Edges stay near the baseline.
struct TalkLevelFill: View {
    var levels: AudioLevels
    var transmitting: Bool
    var receiving: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { _ in
            TalkLevelCanvas(
                samples: levels.meter.history(remoteWanted: receiving && !transmitting),
                live: transmitting || receiving,
                subtler: receiving && !transmitting
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var frameInterval: Double {
        (transmitting || receiving) ? 1.0 / 45.0 : 1.0 / 8.0
    }
}

private struct TalkLevelCanvas: View {
    var samples: [Float]
    var live: Bool
    var subtler: Bool

    var body: some View {
        Canvas { context, size in
            TalkLevelDraw.draw(context: &context, size: size, samples: samples, live: live, subtler: subtler)
        }
    }
}

private enum TalkLevelDraw {
    private static let teal = Color(red: 62.0 / 255.0, green: 230.0 / 255.0, blue: 208.0 / 255.0)

    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        samples: [Float],
        live: Bool,
        subtler: Bool
    ) {
        guard size.width > 1, size.height > 1, samples.count > 1 else { return }
        context.clip(to: Path(ellipseIn: CGRect(origin: .zero, size: size)))
        let mid = size.height * 0.5
        let reach = size.height * (subtler ? 0.22 : 0.36)
        let last = samples.count - 1
        var points: [CGPoint] = []
        var weight: [CGFloat] = []
        points.reserveCapacity(samples.count)
        weight.reserveCapacity(samples.count)
        for index in samples.indices {
            let across = CGFloat(index) / CGFloat(last)
            let center = sin(across * .pi)
            let window = 0.08 + 0.92 * center
            let gain: CGFloat = subtler ? 0.58 : 1
            let shaped = max(-1, min(1, CGFloat(samples[index]) * gain)) * window
            let x = across * size.width
            points.append(CGPoint(x: x, y: mid - shaped * reach))
            weight.append(abs(shaped))
        }
        var whole = Path()
        whole.move(to: points[0])
        for point in points.dropFirst() {
            whole.addLine(to: point)
        }
        let glow = subtler ? 0.35 : (live ? 0.75 : 0.32)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 7))
            layer.stroke(
                whole,
                with: .color(teal.opacity(glow)),
                style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
            )
        }
        let style = StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
        for index in 0..<last {
            var segment = Path()
            segment.move(to: points[index])
            segment.addLine(to: points[index + 1])
            let peak = max(weight[index], weight[index + 1])
            context.stroke(segment, with: .color(color(for: peak, live: live)), style: style)
        }
    }

    private static func color(for peak: CGFloat, live: Bool) -> Color {
        if !live { return teal.opacity(0.5) }
        if peak < 0.35 { return teal }
        let mix = min(1, (peak - 0.35) / 0.65)
        return Color(
            red: (62.0 / 255.0) + (0.92 - 62.0 / 255.0) * mix,
            green: (230.0 / 255.0) + (1 - 230.0 / 255.0) * mix,
            blue: (208.0 / 255.0) + (0.97 - 208.0 / 255.0) * mix
        )
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
