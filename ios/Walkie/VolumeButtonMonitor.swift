import AVFoundation
import MediaPlayer
import os
import UIKit
import SwiftUI

/// Volume-up toggles talk while the app is connected and in the foreground.
///
/// The level is parked at half volume. A press counts only from the system
/// volume notification when the new level is above that park point. Presses
/// closer than 350 ms are dropped. Every slider write mutes all volume events
/// for 600 ms, so the glide back to the park point cannot toggle again.
///
/// `MPVolumeView` has to sit on-screen inside the active view (including Mørk
/// modus) or iOS draws the system volume HUD. The view is hosted by SwiftUI.
/// The unpublished volume notification is the only press source. This target
/// is sideloaded, not shipped through the App Store.
@MainActor
final class VolumeButtonMonitor {
    static let parkLevel: Float = 0.5
    private static let pressEpsilon: Float = 0.03
    private static let pressDebounce: TimeInterval = 0.35
    private static let ignoreAfterWrite: TimeInterval = 0.60

    private let log = Logger(subsystem: "com.skuyng.walkie", category: "volume")
    private let volumeViews = NSHashTable<MPVolumeView>.weakObjects()

    private var onVolumeUp: (@MainActor () -> Void)?
    private var enabled = false
    private var ready = false
    private var savedVolume: Float?
    private var ignoreUntil = Date.distantPast
    private var lastAcceptedPress = Date.distantPast
    private var notificationTokens: [NSObjectProtocol] = []
    private var writeGeneration = 0
    private var loggedMissingSlider = false

    func attach(_ view: MPVolumeView) {
        let already = volumeViews.allObjects.contains { $0 === view }
        volumeViews.add(view)
        guard enabled, ready, !already else { return }
        let current = AVAudioSession.sharedInstance().outputVolume
        guard abs(current - Self.parkLevel) > Self.pressEpsilon else { return }
        park()
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
        savedVolume = AVAudioSession.sharedInstance().outputVolume
        ready = true
        park()
    }

    func stop() {
        guard enabled || savedVolume != nil else { return }
        enabled = false
        ready = false
        writeGeneration += 1
        onVolumeUp = nil
        stopObservers()
        if let savedVolume {
            writeVolume(savedVolume)
            self.savedVolume = nil
        }
    }

    private func installObserversIfNeeded() {
        guard notificationTokens.isEmpty else { return }
        let session = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        for name in ["AVSystemController_SystemVolumeDidChangeNotification", "SystemVolumeDidChange"] {
            notificationTokens.append(center.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: nil
            ) { [weak self] note in
                guard let self else { return }
                let info = note.userInfo ?? [:]
                let reason = (info["AVSystemController_AudioVolumeChangeReasonNotificationParameter"] as? String)
                    ?? (info["Reason"] as? String)
                    ?? ""
                let volume = Self.volume(from: info)
                self.deliver {
                    self.handleVolumeNotification(reason: reason, volume: volume)
                }
            })
        }
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.deliver {
                guard let self, self.enabled, self.ready else { return }
                guard Date() >= self.ignoreUntil else { return }
                self.park()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.deliver {
                guard let self, self.enabled, self.ready else { return }
                guard Date() >= self.ignoreUntil else { return }
                self.park()
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
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    /// One source: the system volume notification. Slider writes and their
    /// glide are ignored wholesale, and only a level above the park point can
    /// toggle — at most once per debounce window.
    private func handleVolumeNotification(reason: String, volume: Float?) {
        guard enabled, ready else { return }
        if Date() < ignoreUntil { return }
        guard reason == "ExplicitVolumeChange" else { return }
        let value = volume ?? AVAudioSession.sharedInstance().outputVolume
        guard value > Self.parkLevel + Self.pressEpsilon else {
            if value < Self.parkLevel - Self.pressEpsilon {
                park()
            }
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastAcceptedPress) >= Self.pressDebounce else { return }
        lastAcceptedPress = now
        log.info("Volume up")
        onVolumeUp?()
        park()
    }

    /// Parks the level. Events caused by this write, including an explicit
    /// reason and any step of the glide, cannot toggle.
    private func park() {
        guard enabled else { return }
        ignoreUntil = Date().addingTimeInterval(Self.ignoreAfterWrite)
        writeGeneration += 1
        let generation = writeGeneration
        if writeVolume(Self.parkLevel, muting: true) { return }
        Task { @MainActor in
            for _ in 0..<5 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard self.enabled, generation == self.writeGeneration else { return }
                if self.writeVolume(Self.parkLevel, muting: true) { return }
            }
        }
    }

    @discardableResult
    private func writeVolume(_ value: Float, muting: Bool = false) -> Bool {
        guard let slider = sliderInHierarchy() else {
            if !loggedMissingSlider {
                loggedMissingSlider = true
                log.error("Volume slider is not in the window yet")
            }
            return false
        }
        loggedMissingSlider = false
        if muting {
            ignoreUntil = Date().addingTimeInterval(Self.ignoreAfterWrite)
        }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
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

/// On-screen volume slider. Alpha stays just above zero so iOS suppresses the
/// system HUD, including over the black Mørk modus overlay.
@MainActor
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
