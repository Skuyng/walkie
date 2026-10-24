import AVFoundation
import Foundation
import os

enum VoiceEngineError: LocalizedError {
    case noInput
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "Fant ingen mikrofon."
        case .failedToStart:
            return "Fikk ikke startet lyden."
        }
    }
}

/// Captures the microphone and plays incoming PCM16 while the session stays active.
///
/// `playAndRecord` + `defaultToSpeaker` + `allowBluetoothHFP` (the current name of
/// `allowBluetooth`) keeps the speakerphone route. The input tap stays installed
/// for the whole connection so iOS treats the app as an active audio app when the
/// phone is locked. Samples are only sent upstream while the microphone flag is open.
final class VoiceEngine {
    var onFailure: ((String) -> Void)?
    var onInterrupted: (() -> Void)?

    private let log = Logger(subsystem: "com.skuyng.walkie", category: "audio")
    private let queue = DispatchQueue(label: "com.skuyng.walkie.audio", qos: .userInteractive)
    private let micOpen = OSAllocatedUnfairLock(initialState: false)
    private let handlerLock = NSLock()
    private var capture: ((Data) -> Void)?

    private var engine: AVAudioEngine?
    private var voicePlayer: AVAudioPlayerNode?
    private var beepPlayer: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var encoder: FormatConverter?
    private var encoderInputKey: String?
    private var decoder: FormatConverter?
    private var shouldRun = false
    private var tapInstalled = false
    private var lastOverride: AVAudioSession.PortOverride?
    private var observers: [NSObjectProtocol] = []
    private var burstStarted = false
    private var primeBuffers: [AVAudioPCMBuffer] = []
    private var primeTimer: DispatchWorkItem?

    private static let wireFormat: AVAudioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: PCM16.sampleRate,
        channels: 1,
        interleaved: false
    )!
    private static let externalPorts: Set<AVAudioSession.Port> = [
        .bluetoothHFP, .bluetoothA2DP, .bluetoothLE, .headphones, .airPlay, .carAudio
    ]

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            self?.handleRouteChange(note)
        })
        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleMediaReset()
        })
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func setCaptureHandler(_ handler: @escaping (Data) -> Void) {
        handlerLock.lock()
        capture = handler
        handlerLock.unlock()
    }

    func setMicrophoneOpen(_ open: Bool) {
        micOpen.withLock { $0 = open }
    }

    func start() throws {
        try queue.sync {
            if shouldRun, engine?.isRunning == true { return }
            try startOnQueue()
        }
    }

    func stop() {
        queue.sync {
            shouldRun = false
            tearDownEngineOnly()
            lastOverride = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    func ensureRunning() {
        queue.async { [weak self] in
            guard let self, self.shouldRun, self.engine?.isRunning != true else { return }
            do {
                try self.startOnQueue()
            } catch {
                self.reportFailure("Lyden stoppet og kunne ikke startes igjen.")
            }
        }
    }

    func playIncoming(_ data: Data) {
        queue.async { [weak self] in
            self?.playIncomingOnQueue(data)
        }
    }

    func playTalkBoundaryBeep(isStart: Bool) {
        queue.async { [weak self] in
            self?.playBeepOnQueue(frequency: isStart ? 988 : 494)
        }
    }

    func markTalkBurstEnded() {
        queue.async { [weak self] in
            guard let self else { return }
            self.primeTimer?.cancel()
            self.primeTimer = nil
            if !self.primeBuffers.isEmpty, let player = self.voicePlayer {
                for buffer in self.primeBuffers {
                    player.scheduleBuffer(buffer)
                }
                if !player.isPlaying { player.play() }
            }
            self.primeBuffers.removeAll()
            self.burstStarted = false
        }
    }

    private func startOnQueue() throws {
        tearDownEngineOnly()
        var lastError: Error = VoiceEngineError.failedToStart
        for voiceChat in [true, false] {
            do {
                try activateSession(voiceChat: voiceChat)
                try buildAndStart()
                shouldRun = true
                log.info("Audio engine running voiceChat=\(voiceChat, privacy: .public)")
                return
            } catch {
                lastError = error
                log.error("Audio start failed: \(error.localizedDescription, privacy: .public)")
                tearDownEngineOnly()
                lastOverride = nil
                try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            }
        }
        shouldRun = false
        throw lastError
    }

    private func activateSession(voiceChat: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: voiceChat ? .voiceChat : .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try? session.setPreferredSampleRate(PCM16.sampleRate)
        try? session.setPreferredIOBufferDuration(0.04)
        try session.setActive(true)
        applyOutputRoute()
    }

    private func buildAndStart() throws {
        let engine = AVAudioEngine()
        let voice = AVAudioPlayerNode()
        let beep = AVAudioPlayerNode()
        engine.attach(voice)
        engine.attach(beep)

        let rate = AVAudioSession.sharedInstance().sampleRate
        let sampleRate = rate > 0 ? rate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw VoiceEngineError.failedToStart
        }
        engine.connect(voice, to: engine.mainMixerNode, format: format)
        engine.connect(beep, to: engine.mainMixerNode, format: format)
        self.engine = engine
        self.voicePlayer = voice
        self.beepPlayer = beep
        self.playbackFormat = format
        self.tapInstalled = false
        self.encoder = nil
        self.encoderInputKey = nil
        self.burstStarted = false
        self.primeBuffers.removeAll()
        self.primeTimer?.cancel()
        self.primeTimer = nil

        engine.prepare()
        try engine.start()

        let render = voice.outputFormat(forBus: 0)
        if render.sampleRate > 0, render.channelCount > 0 {
            self.playbackFormat = render
        }
        guard let playbackFormat = self.playbackFormat,
              let decoder = FormatConverter(from: Self.wireFormat, to: playbackFormat) else {
            throw VoiceEngineError.failedToStart
        }
        self.decoder = decoder

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw VoiceEngineError.noInput
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }
        tapInstalled = true
        voice.play()
        beep.play()
    }

    private func tearDownEngineOnly() {
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false
        engine?.stop()
        voicePlayer?.stop()
        beepPlayer?.stop()
        engine = nil
        voicePlayer = nil
        beepPlayer = nil
        decoder = nil
        encoder = nil
        encoderInputKey = nil
        primeTimer?.cancel()
        primeTimer = nil
        primeBuffers.removeAll()
        burstStarted = false
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard micOpen.withLock({ $0 }), buffer.frameLength > 0 else { return }
        guard let copy = Self.copyBuffer(buffer) else { return }
        queue.async { [weak self] in
            guard let self, self.shouldRun, let data = self.encode(copy), !data.isEmpty else { return }
            self.handlerLock.lock()
            let handler = self.capture
            self.handlerLock.unlock()
            handler?(data)
        }
    }

    private func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
        let key = "\(buffer.format.sampleRate)|\(buffer.format.channelCount)|\(buffer.format.commonFormat.rawValue)|\(buffer.format.isInterleaved)"
        if encoder == nil || encoderInputKey != key {
            encoder = FormatConverter(from: buffer.format, to: Self.wireFormat)
            encoderInputKey = key
        }
        if let converted = encoder?.convert(buffer),
           let channel = converted.floatChannelData,
           converted.frameLength > 0 {
            let count = Int(converted.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channel[0], count: count))
            return PCM16.encode(samples)
        }
        return encodeNearest(buffer)
    }

    /// Same point-sampling the browser uses, if `AVAudioConverter` cannot run.
    private func encodeNearest(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channels = buffer.floatChannelData else { return nil }
        let inputCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        guard inputCount > 0, channelCount > 0, rate > 0 else { return nil }
        let ratio = rate / PCM16.sampleRate
        let outputCount = max(1, Int(Double(inputCount) / ratio))
        var samples = [Float](repeating: 0, count: outputCount)
        for index in 0..<outputCount {
            let sourceIndex = min(inputCount - 1, Int(Double(index) * ratio))
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channels[channel][sourceIndex]
            }
            samples[index] = sum / Float(channelCount)
        }
        return PCM16.encode(samples)
    }

    private func playIncomingOnQueue(_ data: Data) {
        guard shouldRun, let decoder, let player = voicePlayer, let expected = playbackFormat else { return }
        let bytes = data.prefix(64_000)
        guard let wire = Self.wireBuffer(fromPCM16: bytes), let playback = decoder.convert(wire) else { return }
        guard abs(playback.format.sampleRate - expected.sampleRate) < 1,
              playback.format.channelCount == expected.channelCount else { return }
        if burstStarted {
            player.scheduleBuffer(playback)
            if !player.isPlaying { player.play() }
            return
        }
        primeBuffers.append(playback)
        let frames = primeBuffers.reduce(0) { $0 + Int($1.frameLength) }
        let seconds = Double(frames) / playback.format.sampleRate
        if seconds >= 0.10 {
            beginBurstOnQueue()
        } else {
            primeTimer?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.beginBurstOnQueue()
            }
            primeTimer = item
            queue.asyncAfter(deadline: .now() + 0.07, execute: item)
        }
    }

    private func beginBurstOnQueue() {
        primeTimer?.cancel()
        primeTimer = nil
        guard !primeBuffers.isEmpty, let player = voicePlayer else { return }
        burstStarted = true
        for buffer in primeBuffers {
            player.scheduleBuffer(buffer)
        }
        primeBuffers.removeAll()
        if !player.isPlaying { player.play() }
    }

    private func playBeepOnQueue(frequency: Double) {
        guard shouldRun, let player = beepPlayer else { return }
        let output = player.outputFormat(forBus: 0)
        let format = output.sampleRate > 0 ? output : playbackFormat
        guard let format, let buffer = makeBeep(frequency: frequency, format: format) else { return }
        player.scheduleBuffer(buffer, at: nil, options: [.interrupts])
        if !player.isPlaying { player.play() }
    }

    private func makeBeep(frequency: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return nil }
        let duration = 0.08
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        let fade = max(1, Int(sampleRate * 0.008))
        let channelCount = Int(format.channelCount)
        for index in 0..<Int(frames) {
            let time = Double(index) / sampleRate
            var amplitude = 0.25 * sin(2 * Double.pi * frequency * time)
            if index < fade { amplitude *= Double(index) / Double(fade) }
            let remaining = Int(frames) - index
            if remaining < fade { amplitude *= Double(remaining) / Double(fade) }
            let sample = Float(amplitude)
            for channel in 0..<channelCount {
                channels[channel][index] = sample
            }
        }
        return buffer
    }

    private static func wireBuffer(fromPCM16 data: Data) -> AVAudioPCMBuffer? {
        let samples = PCM16.decode(data)
        guard !samples.isEmpty else { return nil }
        let frames = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: wireFormat, frameCapacity: frames),
              let channel = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            channel[0].update(from: base, count: samples.count)
        }
        return buffer
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frames = buffer.frameLength
        guard frames > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frames) else { return nil }
        copy.frameLength = frames
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in source.indices {
            let byteCount = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            guard byteCount > 0, let src = source[index].mData, let dst = destination[index].mData else { continue }
            dst.copyMemory(from: src, byteCount: byteCount)
        }
        return copy
    }

    private func applyOutputRoute() {
        let session = AVAudioSession.sharedInstance()
        let hasExternal = session.currentRoute.outputs.contains { Self.externalPorts.contains($0.portType) }
        let desired: AVAudioSession.PortOverride = hasExternal ? .none : .speaker
        guard lastOverride != desired else { return }
        do {
            try session.overrideOutputAudioPort(desired)
            lastOverride = desired
        } catch {
            log.error("Output route failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            DispatchQueue.main.async { [weak self] in
                self?.onInterrupted?()
            }
        case .ended:
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            guard options.contains(.shouldResume) else { return }
            queue.async { [weak self] in
                guard let self, self.shouldRun else { return }
                do {
                    try self.startOnQueue()
                } catch {
                    self.reportFailure("Lyden ble avbrutt og kunne ikke startes igjen.")
                }
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        queue.async { [weak self] in
            guard let self, self.shouldRun else { return }
            let rate = AVAudioSession.sharedInstance().sampleRate
            let current = self.playbackFormat?.sampleRate ?? 0
            if current > 0, rate > 0, abs(rate - current) > 1 {
                do {
                    try self.startOnQueue()
                } catch {
                    self.reportFailure("Lydutgangen endret seg, og lyden kunne ikke startes igjen.")
                }
            } else {
                self.applyOutputRoute()
            }
        }
    }

    private func handleMediaReset() {
        queue.async { [weak self] in
            guard let self, self.shouldRun else { return }
            do {
                try self.startOnQueue()
            } catch {
                self.reportFailure("Lyden ble tilbakestilt og kunne ikke startes igjen.")
            }
        }
    }

    private func reportFailure(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(message)
        }
    }
}

private final class FormatConverter {
    private let converter: AVAudioConverter

    init?(from: AVAudioFormat, to: AVAudioFormat) {
        guard from.sampleRate > 0, to.sampleRate > 0, let converter = AVAudioConverter(from: from, to: to) else {
            return nil
        }
        self.converter = converter
    }

    func convert(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0 else { return nil }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let estimate = Double(input.frameLength) * ratio
        let capacity = AVAudioFrameCount(max(32.0, estimate.rounded(.up) + 32.0))
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, statusPointer in
            if supplied {
                statusPointer.pointee = .noDataNow
                return nil
            }
            supplied = true
            statusPointer.pointee = .haveData
            return input
        }
        if status == .error || error != nil || output.frameLength == 0 {
            return nil
        }
        return output
    }
}
