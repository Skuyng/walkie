import AVFoundation
import MediaPlayer
import os
import UIKit

/// Volume-up toggles talk while the app is connected and in the foreground.
///
/// The level is parked at half volume, so a hardware press always has room to
/// move `outputVolume`. Slider writes made by this type are ignored: a flag
/// covers the synchronous notification, and a short window treats the glide
/// back to the parked level as an echo. A later increase, including one that
/// arrives while the glide is still running, still counts. An explicit volume
/// notification also counts when the level cannot rise any further.
///
/// `MPVolumeView` has to sit on-screen inside the active view (including Mørk
/// modus) or iOS draws the system volume HUD. The view is hosted by SwiftUI.
/// The unpublished volume notification is observed because it still fires at
/// the end of the scale. This target is sideloaded, not shipped through the
/// App Store.
@MainActor
final class VolumeButtonMonitor {
    static let parkLevel: Float = 0.5
    private static let pressThreshold: Float = 0.02
    /// Same reported level inside this window is one press, not two.
    /// A higher step is not held back by the window.
    private static let echoWindow: TimeInterval = 0.08
    private static let topOfScale: Float = 1 - (1.0 / 16.0) - 0.02

    private let log = Logger(subsystem: "com.skuyng.walkie", category: "volume")
    private let volumeViews = NSHashTable<MPVolumeView>.weakObjects()
    private nonisolated let writeGate = WriteGate()

    private var onVolumeUp: (@MainActor () -> Void)?
    private var enabled = false
    private var ready = false
    private var resetting = false
    private var savedVolume: Float?
    private var anchor: Float = 0.5
    /// Volume we are gliding away from. The same reading shortly afterwards is
    /// the echo of one press. Samples strictly between it and the park point
    /// are the slider write, not a new press. A higher step is neither.
    private var glideFrom: Float?
    private var sameLevelUntil = Date.distantPast
    private var glideUntil = Date.distantPast
    private var observation: NSKeyValueObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var writeGeneration = 0
    private var loggedMissingSlider = false

    func attach(_ view: MPVolumeView) {
        let already = volumeViews.allObjects.contains { $0 === view }
        volumeViews.add(view)
        guard enabled, !already else { return }
        beginReset(covering: anchor)
    }

    func detach(_ view: MPVolumeView) {
        volumeViews.remove(view)
    }

    func start(onVolumeUp: @escaping @MainActor () -> Void) {
        self.onVolumeUp = onVolumeUp
        let starting = !enabled
        enabled = true
        installObserversIfNeeded()
        guard starting else { return }
        let current = AVAudioSession.sharedInstance().outputVolume
        savedVolume = current
        anchor = current
        ready = true
        beginReset(covering: current)
    }

    func stop() {
        guard enabled || savedVolume != nil else { return }
        enabled = false
        ready = false
        resetting = false
        writeGeneration += 1
        onVolumeUp = nil
        glideFrom = nil
        stopObservers()
        if let savedVolume {
            apply(savedVolume)
            self.savedVolume = nil
        }
    }

    private func installObserversIfNeeded() {
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let volume = change.newValue else { return }
            guard let self else { return }
            if self.writeGate.isWriting { return }
            self.deliver {
                self.handle(volume: volume, explicit: false)
            }
        }
        let center = NotificationCenter.default
        for name in ["AVSystemController_SystemVolumeDidChangeNotification", "SystemVolumeDidChange"] {
            // `queue: nil` delivers on the posting thread, including inside
            // `setValue`, so the write flag can drop our own slider writes.
            notificationTokens.append(center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: nil
            ) { [weak self] note in
                guard let self, !self.writeGate.isWriting else { return }
                let info = note.userInfo ?? [:]
                let reason = (info["AVSystemController_AudioVolumeChangeReasonNotificationParameter"] as? String)
                    ?? (info["Reason"] as? String)
                    ?? ""
                let volume = Self.volume(from: info)
                self.deliver {
                    self.handleExplicitChange(reason: reason, volume: volume)
                }
            })
        }
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.deliver {
                guard let self, self.enabled else { return }
                self.beginReset(covering: AVAudioSession.sharedInstance().outputVolume)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.deliver {
                guard let self, self.enabled else { return }
                self.beginReset(covering: AVAudioSession.sharedInstance().outputVolume)
            }
        })
    }

    private nonisolated func deliver(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in
                body()
            }
        }
    }

    private func stopObservers() {
        observation?.invalidate()
        observation = nil
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func handleExplicitChange(reason: String, volume: Float?) {
        guard enabled, ready else { return }
        if !reason.isEmpty && reason != "ExplicitVolumeChange" {
            beginReset(covering: volume ?? AVAudioSession.sharedInstance().outputVolume)
            return
        }
        let value = volume ?? AVAudioSession.sharedInstance().outputVolume
        handle(volume: value, explicit: true)
    }

    private func handle(volume: Float, explicit: Bool) {
        guard enabled, ready else { return }
        if abs(volume - Self.parkLevel) <= Self.pressThreshold {
            anchor = Self.parkLevel
            resetting = false
            return
        }
        if isEcho(volume) { return }
        if volume > anchor + Self.pressThreshold {
            registerPress(at: volume)
            return
        }
        // Hardware presses still notify when the level cannot move any higher.
        if explicit, volume >= Self.topOfScale, volume >= anchor - Self.pressThreshold {
            registerPress(at: volume)
            return
        }
        if volume < anchor - Self.pressThreshold, !resetting {
            beginReset(covering: anchor)
        }
    }

    private func isEcho(_ volume: Float) -> Bool {
        guard let from = glideFrom else { return false }
        if abs(volume - from) <= Self.pressThreshold, Date() < sameLevelUntil {
            return true
        }
        guard Date() < glideUntil else { return false }
        let low = min(from, Self.parkLevel) - Self.pressThreshold
        let high = max(from, Self.parkLevel) + Self.pressThreshold
        let onGlide = volume >= low && volume <= high
        let closerToPark = abs(volume - Self.parkLevel) + Self.pressThreshold < abs(from - Self.parkLevel)
        return onGlide && closerToPark
    }

    private func registerPress(at volume: Float) {
        // Arm the echo before the toggle, so a re-entrant slider notification
        // for this same reading cannot toggle twice.
        glideFrom = volume
        sameLevelUntil = Date().addingTimeInterval(Self.echoWindow)
        glideUntil = Date().addingTimeInterval(0.35)
        log.info("Volume up")
        onVolumeUp?()
        beginReset(covering: volume)
    }

    /// Writes the parked level. Samples on the glide back from `observed` are
    /// an echo; a higher step still toggles.
    private func beginReset(covering observed: Float) {
        writeGeneration += 1
        let generation = writeGeneration
        resetting = true
        glideFrom = observed
        sameLevelUntil = Date().addingTimeInterval(Self.echoWindow)
        glideUntil = Date().addingTimeInterval(0.35)
        let wrote = apply(Self.parkLevel)
        guard !wrote else {
            scheduleResetEnd(generation)
            return
        }
        Task { @MainActor in
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard self.enabled, generation == self.writeGeneration else { return }
                if self.apply(Self.parkLevel) { break }
            }
            self.scheduleResetEnd(generation)
        }
    }

    private func scheduleResetEnd(_ generation: Int) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard generation == self.writeGeneration else { return }
            if abs(AVAudioSession.sharedInstance().outputVolume - Self.parkLevel) <= Self.pressThreshold {
                self.anchor = Self.parkLevel
            }
            self.resetting = false
        }
    }

    @discardableResult
    private func apply(_ value: Float) -> Bool {
        guard let slider = sliderInHierarchy() else {
            if !loggedMissingSlider {
                loggedMissingSlider = true
                log.error("Volume slider is not in the window yet")
            }
            return false
        }
        loggedMissingSlider = false
        writeGate.begin()
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
        writeGate.end()
        return true
    }

    private func sliderInHierarchy() -> UISlider? {
        let views = volumeViews.allObjects
        let visible = views.first { $0.window != nil } ?? views.first
        guard let visible else { return nil }
        visible.layoutIfNeeded()
        return findSlider(in: visible)
    }

    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let slider = findSlider(in: subview) { return slider }
        }
        return nil
    }

    private nonisolated static func volume(from info: [AnyHashable: Any]) -> Float? {
        let keys = [
            "AVSystemController_AudioVolumeNotificationParameter",
            "Volume"
        ]
        for key in keys {
            if let value = info[key] as? Float { return value }
            if let value = info[key] as? Double { return Float(value) }
            if let value = info[key] as? NSNumber { return value.floatValue }
        }
        return nil
    }
}

/// Set around `UISlider.setValue` so a volume notification posted from that
/// write is not treated as a hardware press. Checked from the posting thread.
private final class WriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func begin() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func end() {
        lock.lock()
        value = false
        lock.unlock()
    }

    var isWriting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// On-screen volume slider. Alpha stays just above zero so iOS suppresses the
/// system HUD, including over the black Mørk modus overlay.
struct HiddenSystemVolumeView: UIViewRepresentable {
    let session: WalkieSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeUIView(context: Context) -> MPVolumeView {
        HiddenVolumeSliderView(frame: CGRect(x: 0, y: 0, width: 80, height: 24))
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        uiView.alpha = 0.01
        uiView.isHidden = false
        context.coordinator.session = session
        session.attachSystemVolumeView(uiView)
    }

    static func dismantleUIView(_ uiView: MPVolumeView, coordinator: Coordinator) {
        let session = coordinator.session
        Task { @MainActor in
            session?.detachSystemVolumeView(uiView)
        }
    }

    final class Coordinator {
        weak var session: WalkieSession?
        init(session: WalkieSession) {
            self.session = session
        }
    }
}

/// Keeps alpha just above zero. SwiftUI must not be allowed to mark the view
/// hidden, or the system volume HUD comes back.
private final class HiddenVolumeSliderView: MPVolumeView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var alpha: CGFloat {
        get { super.alpha }
        set { super.alpha = 0.01 }
    }

    override var isHidden: Bool {
        get { false }
        set { super.isHidden = false }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        super.alpha = 0.01
        super.isHidden = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        super.alpha = 0.01
        super.isHidden = false
        clipsToBounds = true
    }

    private func configure() {
        super.alpha = 0.01
        backgroundColor = .clear
        clipsToBounds = true
        showsRouteButton = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }
}
