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
    private(set) var micTrace = [Float](repeating: 0, count: Self.traceCount)
    private(set) var remoteTrace = [Float](repeating: 0, count: Self.traceCount)
    private var task: Task<Void, Never>?
    private var micState: Float = 0
    private var remoteState: Float = 0
    private var micBeat = 0
    private var remoteBeat = 0

    /// One monitor beat: flat, small P, sharp QRS, T, then rest. About two beats a second.
    private static let beat: [Float] = [
        0, 0, 0.07, 0,
        -0.22, 1, -0.5, 0,
        0, 0.18, 0.22, 0.08,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ]
    private static let traceCount = 96

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
                let micSample = self.shaped(micNext, cursor: &self.micBeat, gain: 1)
                let remoteSample = self.shaped(remoteNext, cursor: &self.remoteBeat, gain: 0.62)
                self.push(&self.micTrace, micSample)
                self.push(&self.remoteTrace, remoteSample)
                try? await Task.sleep(for: .milliseconds(22))
            }
        }
    }

    /// Silence stays on the baseline. Voice prints a spike whose height follows the level.
    private func shaped(_ level: Float, cursor: inout Int, gain: Float) -> Float {
        let span = max(0, level - 0.2) / 0.8
        let sample = Self.beat[cursor] * span * gain
        cursor += 1
        if cursor >= Self.beat.count { cursor = 0 }
        return sample
    }

    private func push(_ trace: inout [Float], _ value: Float) {
        if !trace.isEmpty { trace.removeFirst() }
        trace.append(value)
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

/// One glowing trace across the middle of the button. Flat in silence, ECG spikes while someone speaks.
struct TalkLevelFill: View {
    @ObservedObject var levels: AudioLevels
    var transmitting: Bool
    var receiving: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { _ in
            TalkLevelCanvas(samples: trace, bright: transmitting, subtler: receiving && !transmitting)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var trace: [Float] {
        if transmitting { return levels.micTrace }
        if receiving { return levels.remoteTrace }
        return levels.micTrace
    }

    private var frameInterval: Double {
        (transmitting || receiving) ? 1.0 / 45.0 : 1.0 / 8.0
    }
}

private struct TalkLevelCanvas: View {
    var samples: [Float]
    var bright: Bool
    var subtler: Bool

    var body: some View {
        Canvas { context, size in
            TalkLevelDraw.draw(context: &context, size: size, samples: samples, bright: bright, subtler: subtler)
        }
    }
}

private enum TalkLevelDraw {
    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        samples: [Float],
        bright: Bool,
        subtler: Bool
    ) {
        guard size.width > 1, size.height > 1, samples.count > 1 else { return }
        context.clip(to: Path(ellipseIn: CGRect(origin: .zero, size: size)))
        let mid = size.height * 0.5
        let topReserve = size.height * 0.12 + 48
        let bottomReserve = size.height * 0.14 + 36
        let reach = max(10, min(mid - topReserve, mid - bottomReserve))
        var path = Path()
        let last = samples.count - 1
        for index in samples.indices {
            let x = size.width * CGFloat(index) / CGFloat(last)
            let y = mid - CGFloat(samples[index]) * reach
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        let glow = subtler ? 0.28 : (bright ? 0.62 : 0.24)
        let core = subtler ? 0.55 : (bright ? 1 : 0.45)
        let wide = StrokeStyle(lineWidth: subtler ? 6 : 9, lineCap: .round, lineJoin: .round)
        let thin = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
        context.stroke(path, with: .color(Aurora.green.opacity(glow)), style: wide)
        context.stroke(path, with: .color(Aurora.teal.opacity(core)), style: thin)
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
