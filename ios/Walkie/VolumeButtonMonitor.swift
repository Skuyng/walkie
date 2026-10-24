import AVFoundation
import MediaPlayer
import os
import UIKit

/// Volume-up as a push-to-talk toggle while this app is in the foreground.
///
/// `AVAudioSession.outputVolume` is KVO-observable once the play-and-record
/// session is active. A press that raises the level calls `onVolumeUp` and
/// then writes the previous level back through a hidden `MPVolumeView` slider,
/// so the button can be pressed again. A press that lowers the level is kept.
/// The system volume HUD stays hidden while the monitor is running, because
/// that is what an in-window `MPVolumeView` does.
///
/// The hardware buttons do not move `outputVolume` at the top of the scale, so
/// a level that is already at maximum is parked one step down when monitoring
/// starts. That single nudge is what makes a repeated volume-up press visible.
@MainActor
final class VolumeButtonMonitor {
    private let log = Logger(subsystem: "com.skuyng.walkie", category: "volume")
    private static let volumeStep: Float = 1.0 / 16.0
    private static let changeThreshold: Float = 0.02

    private var onVolumeUp: (@MainActor () -> Void)?
    private var enabled = false
    private var observing = false
    private var ready = false
    private var resting: Float = 0.5
    private var lastVolumeUpAt = Date.distantPast
    private var observation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private var notificationTokens: [NSObjectProtocol] = []
    private var installGeneration = 0
    private var baselineGeneration = 0
    private var writeGeneration = 0
    private var observeGeneration = 0

    func start(onVolumeUp: @escaping @MainActor () -> Void) {
        self.onVolumeUp = onVolumeUp
        enabled = true
        installNotificationsIfNeeded()
        guard ensureVolumeView() else {
            scheduleInstallRetry()
            return
        }
        if !observing {
            beginObserving()
        }
    }

    func stop() {
        enabled = false
        ready = false
        onVolumeUp = nil
        installGeneration += 1
        baselineGeneration += 1
        writeGeneration += 1
        stopObserving()
        volumeView?.removeFromSuperview()
        volumeView = nil
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    private func scheduleInstallRetry() {
        installGeneration += 1
        let generation = installGeneration
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard self.enabled, generation == self.installGeneration else { return }
                if self.ensureVolumeView() {
                    if !self.observing {
                        self.beginObserving()
                    }
                    return
                }
            }
            self.log.error("No window for the hidden volume slider")
        }
    }

    private func ensureVolumeView() -> Bool {
        if volumeView != nil { return true }
        guard let window = Self.hostWindow() else { return false }
        let view = MPVolumeView(frame: CGRect(x: -320, y: -320, width: 160, height: 40))
        view.alpha = 0.01
        view.showsRouteButton = false
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        window.addSubview(view)
        volumeView = view
        return true
    }

    private func beginObserving() {
        let session = AVAudioSession.sharedInstance()
        resting = Self.withHeadroom(session.outputVolume)
        ready = false
        baselineGeneration += 1
        observeGeneration += 1
        let generation = baselineGeneration
        let observed = observeGeneration
        observation = session.observe(\.outputVolume, options: [.new]) { [weak self] audioSession, _ in
            let volume = audioSession.outputVolume
            Task { @MainActor in
                guard let self, observed == self.observeGeneration else { return }
                self.handle(volume: volume)
            }
        }
        observing = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard self.observing, self.enabled, generation == self.baselineGeneration else { return }
            self.captureRestingVolume()
            if abs(AVAudioSession.sharedInstance().outputVolume - self.resting) > 0.001 {
                self.log.info("Parking volume at \(self.resting, privacy: .public) so volume-up can register")
                self.writeRestingVolume()
                for _ in 0..<8 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard self.observing, self.enabled, generation == self.baselineGeneration else { return }
                    if abs(AVAudioSession.sharedInstance().outputVolume - self.resting) < Self.changeThreshold {
                        break
                    }
                    self.writeRestingVolume()
                }
            }
            guard self.observing, self.enabled, generation == self.baselineGeneration else { return }
            self.ready = true
        }
    }

    private func stopObserving() {
        observeGeneration += 1
        observation?.invalidate()
        observation = nil
        observing = false
        ready = false
    }

    private func handle(volume: Float) {
        guard enabled, observing, ready else { return }
        if volume > resting + Self.changeThreshold {
            let now = Date()
            if now.timeIntervalSince(lastVolumeUpAt) > 0.12 {
                lastVolumeUpAt = now
                log.info("Volume up")
                onVolumeUp?()
            }
            writeRestingVolume()
            return
        }
        if volume + Self.changeThreshold < resting {
            resting = volume
            writeGeneration += 1
            log.info("Volume down kept at \(volume, privacy: .public)")
        }
    }

    /// Route changes and interruptions move `outputVolume` without a button press.
    private func rebaseline() {
        guard observing else { return }
        ready = false
        baselineGeneration += 1
        let generation = baselineGeneration
        captureRestingVolume()
        writeGeneration += 1
        if abs(AVAudioSession.sharedInstance().outputVolume - resting) > 0.001 {
            writeRestingVolume()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard self.observing, self.enabled, generation == self.baselineGeneration else { return }
            self.captureRestingVolume()
            if abs(AVAudioSession.sharedInstance().outputVolume - self.resting) > 0.001 {
                self.writeRestingVolume()
            }
            guard self.observing, self.enabled, generation == self.baselineGeneration else { return }
            self.ready = true
        }
    }

    private func captureRestingVolume() {
        resting = Self.withHeadroom(AVAudioSession.sharedInstance().outputVolume)
    }

    private func writeRestingVolume() {
        writeGeneration += 1
        let generation = writeGeneration
        let delays: [UInt64] = [0, 30_000_000, 90_000_000, 180_000_000]
        Task { @MainActor in
            for delay in delays {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard self.enabled, generation == self.writeGeneration else { return }
                self.applyVolume(self.resting)
            }
        }
    }

    @discardableResult
    private func applyVolume(_ value: Float) -> Bool {
        volumeView?.layoutIfNeeded()
        guard let slider = findSlider() else { return false }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
        return true
    }

    private func findSlider() -> UISlider? {
        guard let volumeView else { return nil }
        return findSlider(in: volumeView)
    }

    private func findSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for subview in view.subviews {
            if let slider = findSlider(in: subview) { return slider }
        }
        return nil
    }

    private func installNotificationsIfNeeded() {
        guard notificationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebaseline()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebaseline()
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                self.stopObserving()
                self.beginObserving()
            }
        })
    }

    /// Leave one hardware step of headroom at the top of the scale.
    private static func withHeadroom(_ volume: Float) -> Float {
        let ceiling = 1 - volumeStep
        if volume >= 1 - (volumeStep / 2) {
            return ceiling
        }
        return min(max(volume, 0), 1)
    }

    private static func hostWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }
}
