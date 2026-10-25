import AVFoundation
import Darwin
import QuartzCore
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

/// Hardware atomic. One writer publishes the cursor only after the slots are filled.
final class AtomicWord: @unchecked Sendable {
    private var raw = Int64(0)

    func load() -> Int {
        Int(OSAtomicAdd64Barrier(0, &raw))
    }

    func store(_ newValue: Int) {
        while true {
            let seen = OSAtomicAdd64Barrier(0, &raw)
            if OSAtomicCompareAndSwap64Barrier(seen, Int64(newValue), &raw) { return }
        }
    }
}

/// Lock-free sample history. The audio tap writes; Canvas reads. No @Published updates.
final class WaveRing: @unchecked Sendable {
    static let capacity = 512
    private static let mask = capacity - 1

    private let micValue: UnsafeMutablePointer<Float>
    private let micTime: UnsafeMutablePointer<Double>
    private let remoteValue: UnsafeMutablePointer<Float>
    private let remoteTime: UnsafeMutablePointer<Double>
    private let micCursor = AtomicWord()
    private let remoteCursor = AtomicWord()
    private let micHiddenBefore = AtomicWord()
    private let remoteHiddenBefore = AtomicWord()
    /// Smoothed on the main thread only, from the canvas.
    private var shownLevel: CGFloat = 0
    private var shownAt: Double = 0

    init() {
        micValue = .allocate(capacity: Self.capacity)
        micTime = .allocate(capacity: Self.capacity)
        remoteValue = .allocate(capacity: Self.capacity)
        remoteTime = .allocate(capacity: Self.capacity)
        micValue.initialize(repeating: 0, count: Self.capacity)
        micTime.initialize(repeating: 0, count: Self.capacity)
        remoteValue.initialize(repeating: 0, count: Self.capacity)
        remoteTime.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        micValue.deallocate()
        micTime.deallocate()
        remoteValue.deallocate()
        remoteTime.deallocate()
    }

    func writeMic(_ buffer: AVAudioPCMBuffer) {
        write(buffer, values: micValue, times: micTime, cursor: micCursor)
    }

    func writeRemote(_ buffer: AVAudioPCMBuffer) {
        write(buffer, values: remoteValue, times: remoteTime, cursor: remoteCursor)
    }

    func hideMic() {
        micHiddenBefore.store(Self.stamp(CACurrentMediaTime()))
    }

    func hideRemote() {
        remoteHiddenBefore.store(Self.stamp(CACurrentMediaTime()))
    }

    /// Fast attack, light release. Main thread only.
    fileprivate func displayLevel(remote: Bool, now: Double) -> CGFloat {
        let raw = level(remote: remote, now: now)
        let dt = shownAt == 0 ? 0.008 : min(0.05, max(0.001, now - shownAt))
        shownAt = now
        let tau = raw > shownLevel ? 0.016 : 0.05
        let alpha = CGFloat(1 - exp(-dt / tau))
        shownLevel += (raw - shownLevel) * alpha
        if shownLevel < 0.012 { shownLevel = 0 }
        return shownLevel
    }

    /// Latest mic loudness, 0 when nothing recent is coming in.
    private func level(remote: Bool, now: Double) -> CGFloat {
        let values = remote ? remoteValue : micValue
        let times = remote ? remoteTime : micTime
        let cursor = remote ? remoteCursor.load() : micCursor.load()
        let hidden = remote ? remoteHiddenBefore.load() : micHiddenBefore.load()
        guard cursor > 0 else { return 0 }
        let newest = times[(cursor - 1) & Self.mask]
        if now - newest > 0.12 || Self.stamp(newest) < hidden { return 0 }
        let count = min(16, cursor)
        var peak: Float = 0
        var index = 0
        while index < count {
            let slot = (cursor - 1 - index) & Self.mask
            if Self.stamp(times[slot]) >= hidden {
                peak = max(peak, abs(values[slot]))
            }
            index += 1
        }
        if peak < 0.06 { return 0 }
        return CGFloat(min(1, peak))
    }

    private func write(
        _ buffer: AVAudioPCMBuffer,
        values: UnsafeMutablePointer<Float>,
        times: UnsafeMutablePointer<Double>,
        cursor: AtomicWord
    ) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        guard frames > 1, channelCount > 0, rate > 0 else { return }
        let used = min(channelCount, 2)
        let buckets = min(16, max(8, frames / 48))
        let chunk = max(1, frames / buckets)
        let duration = Double(frames) / rate
        let step = duration / Double(buckets)
        var time = CACurrentMediaTime() - duration
        let base = cursor.load()
        var offset = 0
        while offset < buckets {
            let start = offset * chunk
            let end = min(frames, start + chunk)
            var chosen: Float = 0
            var chosenAbs: Float = 0
            var index = start
            while index < end {
                var mixed: Float = 0
                var channel = 0
                while channel < used {
                    mixed += channels[channel][index]
                    channel += 1
                }
                mixed /= Float(used)
                if mixed.isFinite {
                    let magnitude = abs(mixed)
                    if magnitude >= chosenAbs {
                        chosenAbs = magnitude
                        chosen = mixed
                    }
                }
                index += 1
            }
            let boosted = max(-1, min(1, chosen * 5.5))
            let slot = (base + offset) & Self.mask
            times[slot] = time
            values[slot] = boosted
            time += step
            offset += 1
        }
        cursor.store(base + buckets)
    }

    private static func stamp(_ time: Double) -> Int {
        Int(max(0, time) * 1000)
    }
}

/// Holds the ring. It does not publish levels into SwiftUI.
final class AudioLevels {
    let wave = WaveRing()
}

/// Display-rate trace. The Canvas reads the ring itself.
struct TalkLevelFill: View {
    var wave: WaveRing
    var transmitting: Bool
    var receiving: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil)) { timeline in
            Canvas { context, size in
                WaveDraw.draw(
                    context: &context,
                    size: size,
                    wave: wave,
                    now: CACurrentMediaTime(),
                    tick: timeline.date.timeIntervalSinceReferenceDate,
                    transmitting: transmitting,
                    receiving: receiving
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private enum WaveDraw {
    private static let teal = Color(red: 62.0 / 255.0, green: 230.0 / 255.0, blue: 208.0 / 255.0)
    private static let stroke = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
    private static let glow = StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)

    static func draw(
        context: inout GraphicsContext,
        size: CGSize,
        wave: WaveRing,
        now: Double,
        tick: TimeInterval,
        transmitting: Bool,
        receiving: Bool
    ) {
        let _ = tick
        guard size.width > 1, size.height > 1 else { return }
        context.clip(to: Path(ellipseIn: CGRect(origin: .zero, size: size)))
        let mid = size.height * 0.5
        let live = transmitting || receiving
        let subtler = receiving && !transmitting
        let amplitude = live ? wave.displayLevel(remote: subtler, now: now) * (subtler ? 0.6 : 1) : 0
        let path = standing(size: size, mid: mid, now: now, amplitude: amplitude)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.stroke(path, with: .color(teal.opacity(0.35)), style: glow)
        }
        context.stroke(path, with: .color(teal), style: stroke)
    }

    /// Fixed points across the button. Each point oscillates on its own; nothing travels sideways.
    private static func standing(size: CGSize, mid: CGFloat, now: Double, amplitude: CGFloat) -> Path {
        let columns = Self.columns
        let reach = size.height * 0.34
        var points: [CGPoint] = []
        points.reserveCapacity(columns + 1)
        var index = 0
        while index <= columns {
            let across = CGFloat(index) / CGFloat(columns)
            let envelope = sin(across * .pi)
            let wobble = sin(Self.hz[index] * now + Self.phase[index]) * 0.68
                + sin(Self.hzB[index] * now + Self.phaseB[index]) * 0.32
            let y = mid - CGFloat(wobble) * envelope * amplitude * reach
            points.append(CGPoint(x: across * size.width, y: y))
            index += 1
        }
        return curve(points, spike: size.height * 0.08, mid: mid, width: size.width)
    }

    private static let columns = 48

    /// Uncorrelated per point. Not a ramp along x, so the motion cannot slide sideways.
    private static let hz: [Double] = Self.spread(seed: 0xC0FFEE, lo: 9, hi: 74)
    private static let hzB: [Double] = Self.spread(seed: 0xBEE5, lo: 17, hi: 91)
    private static let phase: [Double] = Self.spread(seed: 0xA11CE, lo: 0, hi: .pi * 2)
    private static let phaseB: [Double] = Self.spread(seed: 0x51A7, lo: 0, hi: .pi * 2)

    private static func spread(seed: UInt64, lo: Double, hi: Double) -> [Double] {
        var state = seed
        var values: [Double] = []
        values.reserveCapacity(columns + 1)
        var index = 0
        while index <= columns {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state % 10_000) / 9999
            values.append(lo + (hi - lo) * unit)
            index += 1
        }
        return values
    }

    /// Catmull-Rom through ordinary samples. Steep jumps stay straight so spikes stay sharp.
    private static func curve(_ points: [CGPoint], spike: CGFloat, mid: CGFloat, width: CGFloat) -> Path {
        guard let first = points.first else { return Path() }
        var path = Path()
        path.move(to: CGPoint(x: min(first.x, 0), y: mid))
        path.addLine(to: first)
        let last = points.count - 1
        for index in 0..<last {
            let p1 = points[index]
            let p2 = points[index + 1]
            if hypot(p2.x - p1.x, p2.y - p1.y) < 0.5 {
                continue
            }
            if abs(p1.y - p2.y) >= spike {
                path.addLine(to: p2)
                continue
            }
            let p0 = index > 0 ? points[index - 1] : p1
            let p3 = index + 2 <= last ? points[index + 2] : p2
            path.addCurve(
                to: p2,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            )
        }
        path.addLine(to: CGPoint(x: width, y: mid))
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
