import AVFoundation
import MediaPlayer
import os
import UIKit
import SwiftUI

/// Volume-up is hold-to-talk while the app is connected and in the foreground.
///
/// The first explicit step up starts transmitting. Further volume-up events,
/// including repeats at the top of the scale, keep the hold alive. Transmitting
/// stops only after 1.2 s with no volume-up event (1.5 s after the first one).
/// The level is parked back to the middle after the hold ends, never during it,
/// and events caused by that write are ignored.
///
/// `MPVolumeView` has to sit on-screen inside the active view (including Mørk
/// modus) or iOS draws the system volume HUD. The view is hosted by SwiftUI.
/// The unpublished volume notification is the only press source. This target
/// is sideloaded, not shipped through the App Store.
@MainActor
final class VolumeButtonMonitor {
    static let parkLevel: Float = 0.5
    private static let stepEpsilon: Float = 0.01
    private static let parkArrived: Float = 0.02
    private static let ceiling: Float = 0.98
    /// First press. iOS waits before it starts auto-repeat.
    private static let initialGrace: TimeInterval = 1.5
    /// Stay up until this long passes with no further volume-up event.
    private static let repeatGrace: TimeInterval = 1.2
    private static let resetTimeout: TimeInterval = 1.5
    private static let sessionIgnore: TimeInterval = 0.80

    private let log = Logger(subsystem: "com.skuyng.walkie", category: "volume")
    private let volumeViews = NSHashTable<MPVolumeView>.weakObjects()

    private var onHold: (@MainActor (Bool) -> Void)?
    private var enabled = false
    private var ready = false
    private var holding = false
    private var resetting = false
    private var savedVolume: Float?
    private var lastVolume: Float = 0.5
    private var releaseAt = Date.distantPast
    private var sessionIgnoreUntil = Date.distantPast
    /// Blocks a new hold while the post-release park write is still echoing.
    private var parkEchoUntil = Date.distantPast
    private var notificationTokens: [NSObjectProtocol] = []
    #if DEBUG
    var onVolumeEvent: (@MainActor () -> Void)?
    #endif
    private var holdToken = 0
    private var resetGeneration = 0
    private var stoppingHold = false
    private var loggedMissingSlider = false

    func attach(_ view: MPVolumeView) {
        volumeViews.add(view)
    }

    func detach(_ view: MPVolumeView) {
        volumeViews.remove(view)
    }

    func start(onHold: @escaping @MainActor (Bool) -> Void) {
        self.onHold = onHold
        let starting = !enabled
        enabled = true
        installObserversIfNeeded()
        guard starting else { return }
        let current = AVAudioSession.sharedInstance().outputVolume
        savedVolume = current
        lastVolume = current
        resetting = false
        resetGeneration += 1
        ready = true
    }

    /// Audio-session category, mode, or route changes can post volume
    /// notifications. They are not button presses.
    func noteSessionReconfigured() {
        sessionIgnoreUntil = Date().addingTimeInterval(Self.sessionIgnore)
    }

    func stop() {
        guard enabled || savedVolume != nil || holding else { return }
        enabled = false
        ready = false
        resetting = true
        resetGeneration += 1
        holdToken += 1
        releaseAt = .distantPast
        let ended = holding
        holding = false
        let callback = onHold
        onHold = nil
        if ended {
            callback?(false)
        }
        stopObservers()
        if let savedVolume {
            writeVolume(savedVolume)
            self.savedVolume = nil
        }
    }

    private func installObserversIfNeeded() {
        guard notificationTokens.isEmpty else { return }
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

    /// One source: the system volume notification. A rising explicit change
    /// starts a hold; later repeats keep it alive. Parking is not a press.
    private func handleVolumeNotification(reason: String, volume: Float?) {
        guard enabled, ready else { return }
        #if DEBUG
        onVolumeEvent?()
        #endif
        let value = volume ?? AVAudioSession.sharedInstance().outputVolume
        let previous = lastVolume
        lastVolume = value

        if resetting || stoppingHold {
            if !stoppingHold, abs(value - Self.parkLevel) < Self.parkArrived {
                resetting = false
            }
            return
        }
        let sessionEcho = Date() < sessionIgnoreUntil
        guard reason == "ExplicitVolumeChange" else { return }
        if sessionEcho {
            // A category or route change can post an explicit volume event.
            // That must not start a hold. An in-progress hold still tracks repeats.
            if holding, value >= previous - Self.stepEpsilon {
                armRelease(after: Self.repeatGrace)
            }
            return
        }

        let increased = value > previous + Self.stepEpsilon
        let decreased = value < previous - Self.stepEpsilon
        if holding {
            if !decreased {
                armRelease(after: Self.repeatGrace)
            }
        } else if Date() < parkEchoUntil {
            return
        } else if increased || value >= Self.ceiling {
            beginHold()
        }
    }

    private func beginHold() {
        guard !holding else { return }
        holding = true
        releaseAt = .distantPast
        armRelease(after: Self.initialGrace)
        log.info("Volume up")
        onHold?(true)
    }

    private func endHold() {
        guard holding, !stoppingHold else { return }
        stoppingHold = true
        holding = false
        holdToken += 1
        releaseAt = .distantPast
        log.info("Volume released")
        // Park only after release. Ignore that write, and anything stopping
        // talk posts, so neither can start another hold.
        beginPark()
        onHold?(false)
        stoppingHold = false
    }

    /// Moves the release deadline later. A duplicate of the first press must
    /// not replace the longer initial grace with the shorter repeat grace.
    private func armRelease(after delay: TimeInterval) {
        let proposed = Date().addingTimeInterval(delay)
        guard proposed > releaseAt else { return }
        releaseAt = proposed
        holdToken += 1
        let token = holdToken
        let nanoseconds = UInt64(delay * 1_000_000_000)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard token == self.holdToken, self.holding else { return }
            self.endHold()
        }
    }

    /// Parks after the hold has ended. Writing during the hold stops iOS from
    /// repeating the button. The write's own notifications cannot start a hold.
    private func beginPark() {
        guard enabled, !resetting else { return }
        parkEchoUntil = Date().addingTimeInterval(Self.resetTimeout)
        resetting = true
        resetGeneration += 1
        let generation = resetGeneration
        if !writeVolume(Self.parkLevel) {
            Task { @MainActor in
                for _ in 0..<5 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard self.enabled, generation == self.resetGeneration, self.resetting else { return }
                    if self.writeVolume(Self.parkLevel) { break }
                }
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.resetTimeout * 1_000_000_000))
            guard generation == self.resetGeneration, self.resetting else { return }
            self.resetting = false
        }
    }

    @discardableResult
    private func writeVolume(_ value: Float) -> Bool {
        guard let slider = sliderInHierarchy() else {
            if !loggedMissingSlider {
                loggedMissingSlider = true
                log.error("Volume slider is not in the window yet")
            }
            return false
        }
        loggedMissingSlider = false
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
