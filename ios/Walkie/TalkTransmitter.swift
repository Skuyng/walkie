import Foundation

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
/// The on-screen button uses `HoldToTalkTransmitter`. A later type can adopt
/// this protocol with `PTChannelManager` from PushToTalk.framework and call
/// the same start/stop signals. That framework needs the Push to Talk
/// capability on a paid Apple Developer account, so it is not linked here.
/// A free personal team can still build and install this target.
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
