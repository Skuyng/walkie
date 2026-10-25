import AVFoundation
import Foundation
import os

enum VoiceEngineError: LocalizedError, Equatable {
    case noInput
    case failedToStart
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .noInput:
            return "Fant ingen mikrofon."
        case .failedToStart:
            return "Fikk ikke startet lyden."
        case .microphoneDenied:
            return "Walkie får ikke bruke mikrofonen. Åpne Innstillinger og slå på Mikrofon for Walkie."
        }
    }
}

/// Captures the microphone and plays incoming PCM16 while the session stays active.
///
/// `playAndRecord` uses mode `.default`. `.voiceChat` applies heavy echo
/// cancellation and automatic gain that quiet the loudspeaker, so it is not used.
/// `allowBluetoothHFP` keeps a headset call route. A2DP is not requested:
/// on a play-and-record session it pulls playback off the loudspeaker.
/// Høyttaler adds `defaultToSpeaker` and a speaker override, applied again
/// after the engine starts; off uses the receiver unless a headset is connected.
/// Incoming PCM stays 16 kHz and is converted to the hardware rate. The input tap stays
/// installed for the whole connection so iOS treats the app as an active audio
/// app when the phone is locked. Samples are only sent upstream while the
/// microphone flag is open. Switching the speaker does not rebuild the engine.
final class VoiceEngine {
    var onFailure: ((String) -> Void)?
    var onInterrupted: (() -> Void)?
    /// Category, mode, activation, or speaker override changed. Not used for
    /// opening or closing the microphone during talk.
    var onSessionReconfigured: (() -> Void)?

    private let log = Logger(subsystem: "com.skuyng.walkie", category: "audio")
    private let queue = DispatchQueue(label: "com.skuyng.walkie.audio", qos: .userInteractive)
    private let micOpen = OSAllocatedUnfairLock(initialState: false)
    private let handlerLock = NSLock()
    private let levelMeterLock = NSLock()
    private var levelMeter: LevelMeter?
    private var capture: ((Data) -> Void)?

    private var engine: AVAudioEngine?
    private var useSpeaker = true
    /// True while startup or the live engine owns the session, so the idle
    /// volume-HUD activation cannot swap the category underneath a call.
    private var engineOwnsSession = false
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
    private var jitterTimerArmed = false
    private var lastAudioAt = Date.distantPast

    private static let jitterSeconds = 0.14
    private static let jitterHold: TimeInterval = 0.15

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

    /// Live waveform history. Written from the audio queue, read on main.
    func attachLevelMeter(_ meter: LevelMeter) {
        levelMeterLock.lock()
        levelMeter = meter
        levelMeterLock.unlock()
    }

    /// Opens or closes the capture gate only. The `playAndRecord` session stays
    /// as it was for the whole connection; changing category or mode here makes
    /// iOS post volume events and looks like another button press.
    func setMicrophoneOpen(_ open: Bool) {
        micOpen.withLock { $0 = open }
        if !open {
            queue.async { [weak self] in
                self?.currentLevelMeter()?.clearMic()
            }
        }
    }

    func setSpeakerphone(_ enabled: Bool) {
        let apply = { [weak self] in
            guard let self else { return }
            self.useSpeaker = enabled
            guard AVAudioSession.sharedInstance().category == .playAndRecord else { return }
            self.applyOutputRoute(force: true)
            self.ensureRunning()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Active session before the engine starts, so a volume press can hide the
    /// system HUD. Playback avoids the microphone prompt; the call session
    /// replaces it once audio actually starts.
    func activateForSystemVolume() {
        let apply: () -> Void = { [weak self] in
            self?.activateIdleSessionOnMain()
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Drops the launch session when the app backgrounds, without touching a live call.
    func deactivateIdleSessionIfNeeded() {
        let apply: () -> Void = { [weak self] in
            guard let self, self.engineOwnsSession == false else { return }
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func start() throws {
        try startFresh(force: false)
    }

    func stop() {
        queue.sync {
            shouldRun = false
            tearDownEngineOnly()
            lastOverride = nil
        }
        deactivateSession()
    }

    func ensureRunning() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let needsStart = self.queue.sync { self.shouldRun && self.engine?.isRunning != true }
            guard needsStart else { return }
            do {
                try self.startFresh(force: false)
            } catch {
                self.reportFailure(Self.failureMessage(for: error, fallback: "Lyden stoppet og kunne ikke startes igjen."))
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
            self.jitterTimerArmed = false
            if !self.primeBuffers.isEmpty, let player = self.voicePlayer {
                for buffer in self.primeBuffers {
                    player.scheduleBuffer(buffer)
                }
                if !player.isPlaying { player.play() }
            }
            self.primeBuffers.removeAll()
            self.burstStarted = false
            self.lastAudioAt = .distantPast
            self.decoder?.reset()
        }
    }

    /// Session setup stays on the main thread. `inputNode` is only read after
    /// `playAndRecord` is active, because a node created earlier sticks at 0 Hz.
    private func startFresh(force: Bool) throws {
        if Thread.isMainThread {
            try startFreshOnMain(force: force)
        } else {
            var thrown: Error?
            DispatchQueue.main.sync {
                do {
                    try self.startFreshOnMain(force: force)
                } catch {
                    thrown = error
                }
            }
            if let thrown { throw thrown }
        }
    }

    private func startFreshOnMain(force: Bool) throws {
        try requireMicrophonePermission()
        if !force {
            let running = queue.sync { shouldRun && engine?.isRunning == true }
            if running {
                engineOwnsSession = true
                return
            }
        }
        engineOwnsSession = true

        var lastError: Error = VoiceEngineError.failedToStart
        var attempt = 0
        while attempt < 2 {
            attempt += 1
            do {
                queue.sync { self.tearDownEngineOnly() }
                try activateSession()
                try queue.sync {
                    try self.buildAndStart()
                    self.shouldRun = true
                }
                applyOutputRoute(force: true)
                log.info("Audio engine running mode=default")
                return
            } catch VoiceEngineError.noInput where attempt == 1 {
                lastError = VoiceEngineError.noInput
                log.error("Microphone format is 0; reactivating the session and retrying once")
                releaseEngineAndSession()
            } catch {
                lastError = error
                log.error("Audio start failed: \(error.localizedDescription, privacy: .public)")
                releaseEngineAndSession()
                break
            }
        }
        queue.sync { self.shouldRun = false }
        throw lastError
    }

    private func requireMicrophonePermission() throws {
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw VoiceEngineError.microphoneDenied
        }
    }

    private func releaseEngineAndSession() {
        queue.sync {
            self.shouldRun = false
            self.tearDownEngineOnly()
            self.lastOverride = nil
        }
        deactivateSession()
    }

    private func deactivateSession() {
        let deactivate = {
            self.engineOwnsSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
        if Thread.isMainThread {
            deactivate()
        } else {
            DispatchQueue.main.sync(execute: deactivate)
        }
    }

    private func restartAudio(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let allowed = self.queue.sync { self.shouldRun }
            guard allowed else { return }
            do {
                try self.startFresh(force: true)
            } catch {
                self.reportFailure(Self.failureMessage(for: error, fallback: message))
            }
        }
    }

    private static func failureMessage(for error: Error, fallback: String) -> String {
        if let engineError = error as? VoiceEngineError, let description = engineError.errorDescription {
            return description
        }
        return fallback
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: categoryOptions()
        )
        engineOwnsSession = true
        try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        try? session.setPreferredIOBufferDuration(0.04)
        try session.setActive(true)
        applyOutputRoute()
        reportSessionReconfigured()
    }

    private func activateIdleSessionOnMain() {
        if engineOwnsSession { return }
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)
        } catch {
            log.error("Volume session failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func categoryOptions() -> AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP]
        if useSpeaker {
            options.insert(.defaultToSpeaker)
        }
        return options
    }

    private func buildAndStart() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord else {
            log.error("Refusing to open the microphone before playAndRecord is active")
            throw VoiceEngineError.failedToStart
        }

        let engine = AVAudioEngine()
        let voice = AVAudioPlayerNode()
        let beep = AVAudioPlayerNode()
        engine.attach(voice)
        engine.attach(beep)

        let rate = session.sampleRate
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

        // Touch inputNode only after the session is playAndRecord and active.
        guard let inputFormat = tapFormat(for: engine) else {
            throw VoiceEngineError.noInput
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }
        tapInstalled = true

        engine.mainMixerNode.outputVolume = 1
        voice.volume = 1
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
        voice.play()
        beep.play()
    }

    /// `outputFormat` is 0 Hz on a real iPhone when the input node was realized
    /// too early. `inputFormat(forBus:)` is the hardware format and is usable then.
    private func tapFormat(for engine: AVAudioEngine) -> AVAudioFormat? {
        let input = engine.inputNode
        // Read the hardware format first. outputFormat is 0 Hz on device when the
        // node has no converter yet, and reading it first can keep the node there.
        let hardware = input.inputFormat(forBus: 0)
        let output = input.outputFormat(forBus: 0)
        if Self.isUsable(output) {
            log.info("Mic outputFormat \(output.sampleRate, privacy: .public) Hz, \(output.channelCount, privacy: .public) ch")
            return output
        }
        if Self.isUsable(hardware) {
            log.info("Mic outputFormat was 0; using inputFormat \(hardware.sampleRate, privacy: .public) Hz, \(hardware.channelCount, privacy: .public) ch")
            return hardware
        }
        log.error("Mic outputFormat and inputFormat are both 0")
        return nil
    }

    private static func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func tearDownEngineOnly() {
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
        }
        tapInstalled = false
        currentLevelMeter()?.clearMic()
        currentLevelMeter()?.clearRemote()
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
        jitterTimerArmed = false
        lastAudioAt = .distantPast
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard micOpen.withLock({ $0 }), buffer.frameLength > 0 else { return }
        guard let copy = Self.copyBuffer(buffer) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let open = self.micOpen.withLock { $0 }
            if open {
                self.currentLevelMeter()?.appendMic(Self.wavePeaks(copy))
            } else {
                self.currentLevelMeter()?.clearMic()
            }
            guard self.shouldRun, let data = self.encode(copy), !data.isEmpty else { return }
            self.handlerLock.lock()
            let handler = self.capture
            self.handlerLock.unlock()
            handler?(data)
        }
    }

    private func currentLevelMeter() -> LevelMeter? {
        levelMeterLock.lock()
        let meter = levelMeter
        levelMeterLock.unlock()
        return meter
    }

    /// A few signed peaks from this buffer, so the trace follows the real waveform.
    private static func wavePeaks(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channels = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        let rate = buffer.format.sampleRate
        guard frames > 1, channelCount > 0, rate > 0 else { return [] }
        let used = min(channelCount, 2)
        let duration = Double(frames) / rate
        let buckets = max(2, min(16, Int(duration / 0.0035)))
        let chunk = max(1, frames / buckets)
        var peaks: [Float] = []
        peaks.reserveCapacity(buckets)
        var start = 0
        while start < frames && peaks.count < buckets {
            let end = min(frames, start + chunk)
            var chosen: Float = 0
            var chosenAbs: Float = 0
            for index in start..<end {
                var mixed: Float = 0
                for channel in 0..<used {
                    mixed += channels[channel][index]
                }
                mixed /= Float(used)
                guard mixed.isFinite else { continue }
                let magnitude = abs(mixed)
                if magnitude >= chosenAbs {
                    chosenAbs = magnitude
                    chosen = mixed
                }
            }
            let boosted = chosen * 5.5
            peaks.append(max(-1, min(1, boosted)))
            start = end
        }
        return peaks
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
            return PCM16.encode(limitForWire(samples))
        }
        return encodeNearest(buffer)
    }

    /// Soft knee before the PCM16 clip, so loudspeaker peaks are not squared off.
    private func limitForWire(_ samples: [Float]) -> [Float] {
        let knee: Float = 0.7
        let ceiling: Float = 0.98
        let span = 1 - knee
        return samples.map { sample in
            guard sample.isFinite else { return 0 }
            let sign: Float = sample < 0 ? -1 : 1
            let magnitude = abs(sample)
            if magnitude <= knee { return sample }
            let compressed = knee + span * (1 - exp(-(magnitude - knee) / span))
            return sign * min(ceiling, compressed)
        }
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
        return PCM16.encode(limitForWire(samples))
    }

    private func playIncomingOnQueue(_ data: Data) {
        guard shouldRun, let decoder, let player = voicePlayer, let expected = playbackFormat else { return }
        let bytes = data.prefix(64_000)
        guard let wire = Self.wireBuffer(fromPCM16: bytes), let playback = decoder.convert(wire) else { return }
        currentLevelMeter()?.appendRemote(Self.wavePeaks(wire))
        guard abs(playback.format.sampleRate - expected.sampleRate) < 1,
              playback.format.channelCount == expected.channelCount else { return }
        let now = Date()
        if now.timeIntervalSince(lastAudioAt) > 0.25 {
            burstStarted = false
            decoder.reset()
            primeTimer?.cancel()
            primeTimer = nil
            jitterTimerArmed = false
            primeBuffers.removeAll()
        }
        lastAudioAt = now
        if burstStarted {
            player.scheduleBuffer(playback)
            if !player.isPlaying { player.play() }
            return
        }
        primeBuffers.append(playback)
        let frames = primeBuffers.reduce(0) { $0 + Int($1.frameLength) }
        let seconds = Double(frames) / playback.format.sampleRate
        if seconds >= Self.jitterSeconds {
            beginBurstOnQueue()
        } else if !jitterTimerArmed {
            jitterTimerArmed = true
            let item = DispatchWorkItem { [weak self] in
                self?.beginBurstOnQueue()
            }
            primeTimer = item
            queue.asyncAfter(deadline: .now() + Self.jitterHold, execute: item)
        }
    }

    private func beginBurstOnQueue() {
        primeTimer?.cancel()
        primeTimer = nil
        jitterTimerArmed = false
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

    @discardableResult
    private func applyOutputRoute(force: Bool = false) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let hasExternal = session.currentRoute.outputs.contains { Self.externalPorts.contains($0.portType) }
        let desired: AVAudioSession.PortOverride = (hasExternal || !useSpeaker) ? .none : .speaker
        var changed = false
        if outputOptionsNeedUpdate(session) {
            do {
                try session.setCategory(.playAndRecord, mode: session.mode, options: categoryOptions())
                changed = true
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            } catch {
                log.error("Output options failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if force || lastOverride != desired {
            do {
                try session.overrideOutputAudioPort(desired)
                lastOverride = desired
                changed = true
            } catch {
                log.error("Output route failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if changed {
            reportSessionReconfigured()
        }
        return changed
    }

    private func outputOptionsNeedUpdate(_ session: AVAudioSession) -> Bool {
        if session.category != .playAndRecord { return true }
        let options = session.categoryOptions
        if options.contains(.allowBluetoothHFP) == false { return true }
        return options.contains(.defaultToSpeaker) != useSpeaker
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
            restartAudio("Lyden ble avbrutt og kunne ikke startes igjen.")
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let overridden = reasonValue == AVAudioSession.RouteChangeReason.override.rawValue
        let categoryChanged = reasonValue == AVAudioSession.RouteChangeReason.categoryChange.rawValue
        queue.async { [weak self] in
            guard let self, self.shouldRun else { return }
            if overridden || categoryChanged { return }
            let rate = AVAudioSession.sharedInstance().sampleRate
            let current = self.playbackFormat?.sampleRate ?? 0
            if current > 0, rate > 0, abs(rate - current) > 1 {
                self.restartAudio("Lydutgangen endret seg, og lyden kunne ikke startes igjen.")
            } else {
                self.applyOutputRoute()
            }
        }
    }

    private func handleMediaReset() {
        restartAudio("Lyden ble tilbakestilt og kunne ikke startes igjen.")
    }

    private func reportSessionReconfigured() {
        let callback = onSessionReconfigured
        if Thread.isMainThread {
            callback?()
        } else {
            DispatchQueue.main.async {
                callback?()
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

    func reset() {
        converter.reset()
    }
}
