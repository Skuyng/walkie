import Foundation
import MediaPlayer
import UIKit

/// Signals the WebSocket channel that this phone wants the microphone.
@MainActor
protocol ChannelSignaling: AnyObject {
    var canTransmit: Bool { get }
    func sendTalkStart()
    func sendTalkStop()
    func setMicrophoneOpen(_ open: Bool)
}

/// How the user takes the channel.
///
/// The on-screen button uses `HoldToTalkTransmitter` (hold). Volume-up holds
/// the same start/stop signals while the app is connected and in the foreground.
/// A later type can adopt this protocol with `PTChannelManager` from
/// PushToTalk.framework. That framework needs the Push to Talk capability on a
/// paid Apple Developer account, so it is not linked here. A free personal team
/// can still build and install this target.
@MainActor
protocol ChannelTransmitter: AnyObject {
    var isTransmitting: Bool { get }
    func beginTransmitting()
    func endTransmitting()
}

@MainActor
final class HoldToTalkTransmitter: ChannelTransmitter {
    weak var signaling: ChannelSignaling?
    var onChange: (@MainActor (Bool) -> Void)?
    private(set) var isTransmitting = false

    func beginTransmitting() {
        guard !isTransmitting, signaling?.canTransmit == true else { return }
        isTransmitting = true
        onChange?(true)
        signaling?.setMicrophoneOpen(true)
        signaling?.sendTalkStart()
    }

    func endTransmitting() {
        guard isTransmitting else { return }
        isTransmitting = false
        signaling?.setMicrophoneOpen(false)
        signaling?.sendTalkStop()
        onChange?(false)
    }
}

/// Headset and lock-screen play/pause toggle talk. Volume-up stays hold-to-talk.
@MainActor
final class HeadsetTalkControl {
    private var enabled = false
    private var lastToggle = Date.distantPast
    private var onToggle: (() -> Void)?

    func setEnabled(_ enabled: Bool, onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        let center = MPRemoteCommandCenter.shared()
        if enabled {
            UIApplication.shared.beginReceivingRemoteControlEvents()
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [
                MPMediaItemPropertyTitle: "TalkNet",
                MPNowPlayingInfoPropertyIsLiveStream: true
            ]
            center.togglePlayPauseCommand.isEnabled = true
            center.playCommand.isEnabled = true
            center.pauseCommand.isEnabled = true
            center.togglePlayPauseCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                self.deliver { self.toggleFromRemote() }
                return .success
            }
            center.playCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                self.deliver { self.toggleFromRemote() }
                return .success
            }
            center.pauseCommand.addTarget { [weak self] _ in
                guard let self else { return .commandFailed }
                self.deliver { self.toggleFromRemote() }
                return .success
            }
        } else {
            center.togglePlayPauseCommand.removeTarget(nil)
            center.playCommand.removeTarget(nil)
            center.pauseCommand.removeTarget(nil)
            center.togglePlayPauseCommand.isEnabled = false
            center.playCommand.isEnabled = false
            center.pauseCommand.isEnabled = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            UIApplication.shared.endReceivingRemoteControlEvents()
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

    private func toggleFromRemote() {
        let now = Date()
        if now.timeIntervalSince(lastToggle) < 0.35 { return }
        lastToggle = now
        onToggle?()
    }
}
