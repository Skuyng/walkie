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
    private let volumeTick: UIImpactFeedbackGenerator

    init() {
        dispatchPrecondition(condition: .onQueue(.main))
        press = UIImpactFeedbackGenerator(style: .heavy)
        release = UIImpactFeedbackGenerator(style: .soft)
        remoteStart = UINotificationFeedbackGenerator()
        remoteStop = UIImpactFeedbackGenerator(style: .light)
        volumeTick = UIImpactFeedbackGenerator(style: .light)
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

    /// One light tick when the in-app volume crosses a step. Talk haptics are unchanged.
    func tickVolume() {
        onMain { self.fireVolumeTick() }
    }

    /// Light tick when the talk channel changes. Talk press and release are unchanged.
    func tickSelection() {
        onMain { self.fireVolumeTick() }
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
        volumeTick.prepare()
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

    private func fireVolumeTick() {
        volumeTick.impactOccurred(intensity: 0.4)
        volumeTick.prepare()
    }
}

struct AuroraBackground: View {
    var live: Bool
    /// False while the screen is covered or the app is not in front. The field itself is unchanged.
    var moving: Bool = true
    @State private var driver = AuroraDriver()
    @State private var pacing = false

    var body: some View {
        TimelineView(.animation(minimumInterval: (live || pacing) ? 1.0 / 30.0 : 1.0 / 12.0, paused: !moving)) { timeline in
            AuroraFrame(driver: driver, live: live, time: timeline.date.timeIntervalSinceReferenceDate)
        }
        .ignoresSafeArea()
        .onPreferenceChange(AuroraPaceKey.self) { pacing = $0 }
        .onChange(of: live) { _, isLive in
            if isLive { pacing = true }
        }
    }
}

/// Eases the field in over 0.6s and out over 0.9s. Phase is accumulated so the speed change does not jump.
private final class AuroraDriver {
    private var amount: Double = 0
    private var origin: Double = 0
    private var goal: Double = 0
    private var began: Double = 0
    private var span: Double = 0.6
    private var primed = false
    private var marked: Double = 0
    private var phase: Double = 0
    private var phaseY: Double = 0
    private var seen: Double = -1
    private var cached = AuroraSample(amount: 0, phase: 0, phaseY: 0)
    private(set) var busy = false

    func sample(live: Bool, now: Double) -> AuroraSample {
        if now == seen { return cached }
        let next: Double = live ? 1 : 0
        if !primed || next != goal {
            origin = amount
            goal = next
            began = now
            span = next > origin ? 0.6 : 0.9
            primed = true
        }
        let t = span <= 0 ? 1 : min(1, max(0, (now - began) / span))
        amount = origin + (goal - origin) * easeInOut(t)
        if abs(amount - goal) < 0.001 { amount = goal }
        let dt = marked == 0 ? 1.0 / 30.0 : min(0.12, max(0, now - marked))
        marked = now
        let speed = 0.16 + (0.62 - 0.16) * amount
        phase = (phase + dt * speed).truncatingRemainder(dividingBy: .pi * 2)
        phaseY = (phaseY + dt * speed * 0.75).truncatingRemainder(dividingBy: .pi * 2)
        busy = live || amount > 0.01
        cached = AuroraSample(amount: amount, phase: phase, phaseY: phaseY)
        seen = now
        return cached
    }
}

private struct AuroraSample {
    var amount: Double
    var phase: Double
    var phaseY: Double
}

private struct AuroraPaceKey: PreferenceKey {
    static var defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct AuroraFrame: View {
    var driver: AuroraDriver
    var live: Bool
    var time: TimeInterval

    var body: some View {
        AuroraField(sample: driver.sample(live: live, now: time))
            .preference(key: AuroraPaceKey.self, value: driver.busy)
    }
}

private struct AuroraField: View {
    var sample: AuroraSample

    var body: some View {
        ZStack {
            Aurora.ink
            AuroraBlob(sample: sample, color: Aurora.green, phase: 0.4, size: 320, slot: 0)
            AuroraBlob(sample: sample, color: Aurora.teal, phase: 2.1, size: 280, slot: 1)
            AuroraBlob(sample: sample, color: Aurora.violet, phase: 4.2, size: 300, slot: 2)
        }
    }
}

private struct AuroraBlob: View {
    var sample: AuroraSample
    var color: Color
    var phase: Double
    var size: CGFloat
    var slot: Int

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .blur(radius: blur)
            .opacity(opacity)
            .offset(x: driftX, y: driftY)
    }

    private var driftX: CGFloat {
        CGFloat(cos(sample.phase + phase) * spreadX + Double(slot - 1) * 16)
    }

    private var driftY: CGFloat {
        CGFloat(sin(sample.phaseY + phase) * spreadY)
    }

    private var spreadX: Double {
        42 + (110 - 42) * sample.amount
    }

    private var spreadY: Double {
        28 + (86 - 28) * sample.amount
    }

    private var blur: CGFloat {
        CGFloat(84 - 28 * sample.amount)
    }

    private var diameter: CGFloat {
        size * CGFloat(1 + 0.22 * sample.amount)
    }

    /// Idle stays barely visible. Talking and receiving ease up to the full field.
    private var opacity: Double {
        0.04 + (0.78 - 0.04) * sample.amount
    }
}

private func easeInOut(_ t: Double) -> Double {
    if t < 0.5 { return 4 * t * t * t }
    let u = -2 * t + 2
    return 1 - (u * u * u) / 2
}

private func easeOut(_ t: Double) -> Double {
    let u = 1 - t
    return 1 - u * u * u
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
    private var fallFrom: CGFloat = 0
    private var fallBegan: Double = 0
    private var falling = false
    private var veil: Double = 0
    private var veilFrom: Double = 0
    private var veilGoal: Double = 0
    private var veilBegan: Double = 0
    private var veilSpan: Double = 0.2
    private var veilReady = false

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

    /// Fast attack while sound is present. Silence eases to a flat line instead of snapping. Main thread only.
    fileprivate func displayLevel(remote: Bool, live: Bool, gain: CGFloat, now: Double) -> CGFloat {
        let raw = live ? level(remote: remote, now: now) * gain : 0
        if raw < 0.001 {
            if !falling {
                fallFrom = shownLevel
                fallBegan = now
                falling = true
            }
            let t = min(1, max(0, (now - fallBegan) / 0.35))
            shownLevel = fallFrom * CGFloat(1 - easeOut(t))
            if t >= 1 || shownLevel < 0.001 { shownLevel = 0 }
            shownAt = now
            return shownLevel
        }
        falling = false
        let dt = shownAt == 0 ? 0.008 : min(0.05, max(0.001, now - shownAt))
        shownAt = now
        let tau = raw > shownLevel ? 0.016 : 0.05
        let alpha = CGFloat(1 - exp(-dt / tau))
        shownLevel += (raw - shownLevel) * alpha
        return min(1, shownLevel)
    }

    /// Soft fade for the stroke. In 0.2s, out 0.35s, both easeOut. Main thread only.
    fileprivate func lineOpacity(live: Bool, now: Double) -> Double {
        let next: Double = live ? 1 : 0
        if !veilReady || next != veilGoal {
            veilFrom = veil
            veilGoal = next
            veilBegan = now
            veilSpan = live ? 0.2 : 0.35
            veilReady = true
        }
        let t = veilSpan <= 0 ? 1 : min(1, max(0, (now - veilBegan) / veilSpan))
        veil = veilFrom + (veilGoal - veilFrom) * easeOut(t)
        if abs(veil - veilGoal) < 0.001 { veil = veilGoal }
        return veil
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
/// Idle pauses after the existing fade, so a silent button does not redraw every frame.
struct TalkLevelFill: View {
    var wave: WaveRing
    var transmitting: Bool
    var receiving: Bool
    var painting: Bool
    @State private var coasting = false
    @State private var coastToken = 0

    private var live: Bool { transmitting || receiving }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !painting || (!live && !coasting))) { timeline in
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
        .onChange(of: live) { _, talking in
            coastToken += 1
            if talking {
                coasting = true
                return
            }
            let token = coastToken
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                guard token == coastToken else { return }
                coasting = false
            }
        }
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
        let gain: CGFloat = subtler ? 0.6 : 1
        let amplitude = wave.displayLevel(remote: subtler, live: live, gain: gain, now: now)
        let opacity = wave.lineOpacity(live: live, now: now)
        if opacity < 0.004 && amplitude < 0.004 { return }
        let path = standing(size: size, mid: mid, now: now, amplitude: amplitude)
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 3))
            layer.stroke(path, with: .color(teal.opacity(0.35 * opacity)), style: glow)
        }
        context.stroke(path, with: .color(teal.opacity(opacity)), style: stroke)
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

struct TalkNetWordmark: View {
    var mark: CGFloat = 28
    var titleFont: Font = .title3.weight(.semibold)

    var body: some View {
        HStack(spacing: 8) {
            Image("TalkNetLogo")
                .resizable()
                .scaledToFit()
                .frame(width: mark, height: mark)
                .clipShape(RoundedRectangle(cornerRadius: mark * 0.22, style: .continuous))
            Text("TalkNet")
                .font(titleFont)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("TalkNet")
    }
}

struct TuningReadout: View {
    var code: String
    var name: String
    var mode: String
    var transmittingLabel: String
    var receivingLabel: String
    var hint: String
    var expanded: Bool = false
    var action: () -> Void
    @State private var settling = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(code)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: 104)
                    .layoutPriority(-1)
                if !mode.isEmpty {
                    Text(mode)
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .foregroundStyle(mode == "TX" ? Aurora.teal : Aurora.violet)
                        .fixedSize()
                        .accessibilityLabel(mode == "TX" ? transmittingLabel : receivingLabel)
                }
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .animation(.spring(response: 0.34, dampingFraction: 0.86), value: expanded)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(settling ? 0.4 : 1)
        .animation(.easeOut(duration: 0.28), value: settling)
        .onChange(of: code) { _, _ in retune() }
        .accessibilityHint(hint)
    }

    private func retune() {
        settling = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(170))
            settling = false
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
                .font(.headline)
                .lineLimit(1)
        }
    }
}

extension View {
    func auroraCard() -> some View {
        self
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    func auroraField() -> some View {
        self
            .textFieldStyle(.plain)
            .tint(Aurora.teal)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .circular)
                    .fill(Color.white.opacity(0.14))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .circular)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            }
    }
}
