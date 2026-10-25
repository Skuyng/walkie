import AVFoundation
import Foundation
import os

enum VoiceEngineError: LocalizedError, Equatable {
    case noInput
    case failedToStart
    case microphoneDenied

    /// Log text only. Alerts use `AudioAlert` so the in-app language can change them.
    var errorDescription: String? {
        switch self {
        case .noInput:
            return "Couldn't find a microphone."
        case .failedToStart:
            return "Couldn't start audio."
        case .microphoneDenied:
            return "TalkNet can't use the microphone."
        }
    }
}

/// Plays incoming PCM16 for the whole connection.
///
/// While the app is in the foreground and a call is up, one `playAndRecord`
/// graph stays running: voice processing is enabled once, the input tap stays
/// installed, and the send gate stays closed until Talk. Pressing Talk only
/// opens that gate, so the next mic buffer is encoded immediately. The ready
/// chirp is scheduled on the beep player at the same time. Voice processing
/// cancels it from the uplink; if voice processing is unavailable the chirp
/// may leak, and sending still starts immediately.
///
/// Releasing Talk keeps the gate open for about 200 ms, then closes it.
/// The graph is not rebuilt. Background idle tears the tap down, turns voice
/// processing off, and switches to `.playback` so the microphone indicator
/// is off and locked-screen playback still runs. Headset talk from the
/// background pays for one capture start, then sends without waiting for
/// the chirp.
///
/// `playAndRecord` uses mode `.default`. `.voiceChat` quiets the loudspeaker.
/// `allowBluetoothHFP` and `allowBluetoothA2DP` both stay available while
/// capturing. A connected headset keeps the route; Høyttaler adds
/// `defaultToSpeaker` and a speaker override only when nothing external is
/// plugged in. Incoming PCM stays 16 kHz.
final class VoiceEngine {
    var onFailure: ((AudioAlert) -> Void)?
    var onInterrupted: (() -> Void)?
    /// Category, mode, activation, or speaker override changed. Not used for
    /// opening or closing the microphone during talk.
    var onSessionReconfigured: (() -> Void)?
    /// The send gate has closed after Talk, including the release tail.
    /// Invoked on the main queue. A re-press during the tail does not call it.
    var onSendIdle: (() -> Void)?

    private let log = Logger(subsystem: "com.skuyng.walkie", category: "audio")
    private let queue = DispatchQueue(label: "com.skuyng.walkie.audio", qos: .userInteractive)
    private let micOpen = OSAllocatedUnfairLock(initialState: false)
    private let handlerLock = NSLock()
    private let levelMeterLock = NSLock()
    private var levelMeter: WaveRing?
    private let waveArmed = AtomicWord()
    private var capture: ((Data) -> Void)?

    private var engine: AVAudioEngine?
    private var useSpeaker = true
    /// True while startup or the live engine owns the session, so the idle
    /// volume-HUD activation cannot swap the category underneath a call.
    private var engineOwnsSession = false
    private var voicePlayer: AVAudioPlayerNode?
    private var beepPlayer: AVAudioPlayerNode?
    /// Silent loop so a locked phone keeps the playback engine awake without the mic.
    private var keepAlivePlayer: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var encoder: FormatConverter?
    private var encoderInputKey: String?
    private var encoderScratch: AVAudioPCMBuffer?
    private var wireScratch: AVAudioPCMBuffer?
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
    /// True while the local ready chirp owns the beep player.
    private var chirpPlaying = false
    /// Set after voice processing fails once, so the next capture still opens the mic.
    private var voiceProcessingDisabled = false
    /// True while the user is holding Talk. The release tail keeps the gate
    /// open after this becomes false. The foreground graph stays up either way.
    private var wantsCapture = false
    /// Foreground keeps the capture graph warm. Only a real background
    /// transition clears it; the app switcher does not.
    private var appIsActive = true
    private var captureArmed = false
    private var voiceProcessingOn = false
    private var releaseTail: DispatchWorkItem?
    private var releaseGeneration = 0
    private let incomingMuted = OSAllocatedUnfairLock(initialState: false)
    /// Which channel this phone is on, plus open talk-start counts.
    /// Binary frames have no channel id, so a foreign start is the only
    /// client-side reason to drop PCM, and only while this channel is quiet.
    private let inboundRoute = OSAllocatedUnfairLock(initialState: InboundRoute())
    /// Automatic leveler. Separate from the listener's volume slider.
    private var playbackGain: Float = 1
    private let listenGain = OSAllocatedUnfairLock(initialState: Float(1))
    private var playingClip = false
    private var clipGeneration = 0

    private static let jitterSeconds = 0.14
    private static let jitterHold: TimeInterval = 0.15
    /// Frames still sent after the finger lifts, so the last word is not cut.
    private static let releaseTailSeconds: TimeInterval = 0.20

    private struct InboundRoute: Sendable {
        var channel = ""
        var foreignOpen = 0
        var homeOpen = 0
        var accepts: Bool { foreignOpen == 0 || homeOpen > 0 }
    }

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
    func attachLevelMeter(_ meter: WaveRing) {
        levelMeterLock.lock()
        levelMeter = meter
        levelMeterLock.unlock()
    }

    /// Opens the send gate immediately when Talk is held, or starts the release
    /// tail when it is let go. Does not rebuild the audio graph.
    func setMicrophoneOpen(_ open: Bool) {
        if open {
            beginSending()
        } else {
            endSending()
        }
    }

    /// Foreground: keep `playAndRecord`, voice processing, and the input tap,
    /// with the send gate left as it is. Background: cool to playback once the
    /// gate and the release tail are both idle.
    func setCaptureWarm(_ active: Bool) {
        let apply: () -> Void = { [weak self] in
            self?.setCaptureWarmOnMain(active)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// Arms the warm capture graph if needed, then opens the send gate on this
    /// turn. Returns false when the call is down or the microphone cannot start.
    @discardableResult
    func beginSending() -> Bool {
        if Thread.isMainThread {
            return beginSendingOnMain()
        }
        var ready = false
        DispatchQueue.main.sync {
            ready = self.beginSendingOnMain()
        }
        return ready
    }

    /// Closes the send gate after a short tail so the last word still goes out.
    /// The foreground graph stays up.
    func endSending() {
        let run: () -> Void = { [weak self] in
            self?.endSendingOnMain()
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    /// Incoming speech only. 1 is full level after the slow leveler. 0 is silent.
    func setListenGain(_ gain: Float) {
        let clamped = min(1, max(0, gain))
        listenGain.withLock { $0 = clamped }
    }

    func setSpeakerphone(_ enabled: Bool) {
        let apply: () -> Void = { [weak self] in
            guard let self else { return }
            let changed = self.useSpeaker != enabled
            self.useSpeaker = enabled
            guard self.queue.sync(execute: { self.shouldRun }) else { return }
            if !changed && self.warmGraphReady() { return }
            let warm = self.appIsActive || self.warmGraphReady() || self.queue.sync { self.wantsCapture }
            if warm {
                self.applyOutputRoute(force: true)
                self.restoreWarmGraphIfNeeded()
                return
            }
            do {
                try self.startListeningOnMain(force: true)
            } catch {
                self.log.error("Speaker route failed: \(error.localizedDescription, privacy: .public)")
            }
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
        let reset: () -> Void = { [weak self] in
            guard let self else { return }
            self.releaseGeneration += 1
            self.releaseTail?.cancel()
            self.releaseTail = nil
            self.micOpen.withLock { $0 = false }
            self.waveArmed.store(0)
        }
        if Thread.isMainThread {
            reset()
        } else {
            DispatchQueue.main.sync(execute: reset)
        }
        queue.sync { self.wantsCapture = false }
        if appIsActive {
            do {
                try startFresh(force: false)
                return
            } catch {
                log.error("Warm microphone failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if Thread.isMainThread {
            try startListeningOnMain(force: true)
        } else {
            var thrown: Error?
            DispatchQueue.main.sync {
                do {
                    try self.startListeningOnMain(force: true)
                } catch {
                    thrown = error
                }
            }
            if let thrown { throw thrown }
        }
    }

    func stop() {
        let reset: () -> Void = { [weak self] in
            guard let self else { return }
            self.releaseGeneration += 1
            self.releaseTail?.cancel()
            self.releaseTail = nil
            self.micOpen.withLock { $0 = false }
            self.waveArmed.store(0)
        }
        if Thread.isMainThread {
            reset()
        } else {
            DispatchQueue.main.sync(execute: reset)
        }
        queue.sync {
            shouldRun = false
            wantsCapture = false
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
                self.reportFailure(Self.failureAlert(for: error, fallback: .stopped))
            }
        }
    }

    func playIncoming(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.inboundRoute.withLock({ $0.accepts }) else { return }
            self.playIncomingOnQueue(data)
        }
    }

    /// Current channel. Counts reset only when the channel actually changes,
    /// so an inbox refresh does not reopen a foreign transmission.
    func setInboundChannel(_ channel: String) {
        inboundRoute.withLock { state in
            guard state.channel != channel else { return }
            state.channel = channel
            state.foreignOpen = 0
            state.homeOpen = 0
        }
    }

    /// `started` is a talk-start. A room other than the current channel
    /// does not open the speaker.
    func noteInboundTalk(room: String, started: Bool) {
        inboundRoute.withLock { state in
            let foreign = !room.isEmpty && room != state.channel
            if foreign {
                state.foreignOpen = max(0, state.foreignOpen + (started ? 1 : -1))
            } else {
                state.homeOpen = max(0, state.homeOpen + (started ? 1 : -1))
            }
        }
    }

    func acceptsInboundAudio() -> Bool {
        inboundRoute.withLock { $0.accepts }
    }

    func resetInboundTalk() {
        inboundRoute.withLock { state in
            state.foreignOpen = 0
            state.homeOpen = 0
        }
    }

    /// Quiet hours. The capture tap and the speaking indicator are unchanged;
    /// incoming buffers are not scheduled to the speaker.
    func setIncomingMuted(_ muted: Bool) {
        incomingMuted.withLock { $0 = muted }
    }

    /// Plays stored PCM16 through the current speaker route. It is not fed back
    /// into the capture tap.
    func playClip(_ data: Data) {
        let copy = data
        queue.async { [weak self] in
            self?.playClipOnQueue(copy)
        }
    }

    func stopPlaybackClip() {
        queue.async { [weak self] in
            self?.stopPlaybackClipOnQueue()
        }
    }

    func playTalkBoundaryBeep(isStart: Bool) {
        queue.async { [weak self] in
            self?.playBeepOnQueue(frequency: isStart ? 988 : 494)
        }
    }

    /// Soft descending tone for listeners when a remote speaker releases.
    func playRogerTone() {
        queue.async { [weak self] in
            self?.playRogerOnQueue()
        }
    }

    /// Local “you can speak” chirp. It does not gate the microphone: the caller
    /// opens the send gate first, and voice processing keeps the tone off the
    /// uplink. `then` runs on the main queue after playback, or immediately
    /// when the engine is not up.
    func playReadyChirp(then: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async(execute: then)
                return
            }
            guard self.shouldRun, let player = self.beepPlayer else {
                DispatchQueue.main.async(execute: then)
                return
            }
            let output = player.outputFormat(forBus: 0)
            let format = output.sampleRate > 0 ? output : self.playbackFormat
            guard let format, let buffer = self.makeChirp(format: format) else {
                DispatchQueue.main.async(execute: then)
                return
            }
            self.chirpPlaying = true
            player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    self?.chirpPlaying = false
                    DispatchQueue.main.async(execute: then)
                }
            }
            if !player.isPlaying { player.play() }
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
        if appIsActive {
            try startCaptureOnMain(force: force)
        } else {
            try startListeningOnMain(force: force)
        }
    }

    private func setCaptureWarmOnMain(_ active: Bool) {
        appIsActive = active
        guard queue.sync(execute: { shouldRun }) else { return }
        if active {
            guard !warmGraphReady() else { return }
            do {
                try startCaptureOnMain(force: true)
            } catch {
                reportFailure(Self.failureAlert(for: error, fallback: .failedToStart))
                try? startListeningOnMain(force: true)
            }
            return
        }
        let holding = micOpen.withLock { $0 } || releaseTail != nil
        let wants = queue.sync { wantsCapture }
        if holding || wants { return }
        let listening = queue.sync { !captureArmed && engine?.isRunning == true }
        if listening && listeningCategoryMatches() { return }
        do {
            try startListeningOnMain(force: true)
        } catch {
            log.error("Background playback failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func beginSendingOnMain() -> Bool {
        releaseGeneration += 1
        releaseTail?.cancel()
        releaseTail = nil
        guard queue.sync(execute: { shouldRun }) else { return false }
        queue.sync { self.wantsCapture = true }
        if !warmGraphReady() {
            do {
                try startCaptureOnMain(force: true)
            } catch {
                queue.sync { self.wantsCapture = false }
                reportFailure(Self.failureAlert(for: error, fallback: .failedToStart))
                try? startListeningOnMain(force: true)
                return false
            }
        }
        openCaptureGate()
        return micOpen.withLock { $0 }
    }

    private func endSendingOnMain() {
        queue.sync { self.wantsCapture = false }
        let open = micOpen.withLock { $0 }
        guard open else {
            finishReleaseTail()
            return
        }
        releaseGeneration += 1
        let generation = releaseGeneration
        releaseTail?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.releaseGeneration == generation else { return }
            self.finishReleaseTail()
        }
        releaseTail = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseTailSeconds, execute: item)
    }

    /// Closes the gate and tells the session the uplink is idle. Cools to
    /// playback only when the app is already in the background.
    private func finishReleaseTail() {
        let stillHolding = queue.sync { wantsCapture }
        if stillHolding { return }
        releaseTail = nil
        micOpen.withLock { $0 = false }
        waveArmed.store(0)
        currentLevelMeter()?.hideMic()
        let notify = onSendIdle
        let deliver: () -> Void = {
            notify?()
        }
        DispatchQueue.main.async(execute: deliver)
        guard appIsActive == false else { return }
        guard queue.sync(execute: { shouldRun }) else { return }
        let listening = queue.sync { !captureArmed && engine?.isRunning == true }
        if listening && listeningCategoryMatches() { return }
        do {
            try startListeningOnMain(force: true)
        } catch {
            log.error("Playback restore failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openCaptureGate() {
        let armed = queue.sync { captureArmed && tapInstalled && engine?.isRunning == true }
        guard armed else { return }
        micOpen.withLock { $0 = true }
        waveArmed.store(1)
    }

    private func warmGraphReady() -> Bool {
        let running = queue.sync {
            shouldRun && captureArmed && tapInstalled && engine?.isRunning == true
        }
        return running && AVAudioSession.sharedInstance().category == .playAndRecord
    }

    /// Speaker and route changes can stop the engine. Rebuild capture without
    /// clearing the send gate, so a hold that is already open keeps sending.
    private func restoreWarmGraphIfNeeded() {
        if warmGraphReady() { return }
        guard queue.sync(execute: { shouldRun }) else { return }
        do {
            try startCaptureOnMain(force: true)
        } catch {
            reportFailure(Self.failureAlert(for: error, fallback: .failedToStart))
        }
    }

    private func startListeningOnMain(force: Bool) throws {
        if !force {
            let running = queue.sync {
                shouldRun && !captureArmed && engine?.isRunning == true
            }
            if running && listeningCategoryMatches() {
                engineOwnsSession = true
                return
            }
        }
        engineOwnsSession = true
        queue.sync { self.tearDownEngineOnly() }
        try activateListeningSession()
        try queue.sync {
            try self.buildPlaybackGraph()
            self.shouldRun = true
            self.captureArmed = false
        }
        log.info("Playback engine running")
    }

    private func startCaptureOnMain(force: Bool) throws {
        try requireMicrophonePermission()
        if !force {
            let running = queue.sync {
                shouldRun && captureArmed && tapInstalled && engine?.isRunning == true
            }
            if running && AVAudioSession.sharedInstance().category == .playAndRecord {
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
                try activateCaptureSession()
                try queue.sync {
                    try self.buildCaptureGraph()
                    self.shouldRun = true
                    self.captureArmed = true
                }
                applyOutputRoute(force: true)
                log.info("Capture engine running mode=default")
                return
            } catch VoiceEngineError.noInput where attempt == 1 {
                lastError = VoiceEngineError.noInput
                voiceProcessingDisabled = true
                log.error("Microphone format is 0; reactivating the session and retrying once")
                releaseEngineAndSession()
            } catch {
                lastError = error
                log.error("Audio start failed: \(error.localizedDescription, privacy: .public)")
                releaseEngineAndSession()
                if attempt == 1, voiceProcessingDisabled == false {
                    voiceProcessingDisabled = true
                    log.error("Retrying audio without voice processing")
                    continue
                }
                break
            }
        }
        queue.sync {
            self.shouldRun = false
            self.wantsCapture = false
            self.captureArmed = false
        }
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

    private func restartAudio(_ alert: AudioAlert) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let allowed = self.queue.sync { self.shouldRun }
            guard allowed else { return }
            do {
                try self.startFresh(force: true)
            } catch {
                self.reportFailure(Self.failureAlert(for: error, fallback: alert))
            }
        }
    }

    private static func failureAlert(for error: Error, fallback: AudioAlert) -> AudioAlert {
        guard let engineError = error as? VoiceEngineError else { return fallback }
        switch engineError {
        case .noInput:
            return .noInput
        case .failedToStart:
            return .failedToStart
        case .microphoneDenied:
            return .microphoneDenied
        }
    }

    /// Background idle is playback only. No tap and no voice processing, and
    /// `inputNode` is not touched, so the microphone indicator stays off.
    private func activateListeningSession() throws {
        let session = AVAudioSession.sharedInstance()
        reportSessionReconfigured()
        try session.setCategory(.playback, mode: .default, options: [])
        engineOwnsSession = true
        try? session.setPreferredIOBufferDuration(0.04)
        try session.setActive(true)
        lastOverride = nil
        reportSessionReconfigured()
    }

    private func activateCaptureSession() throws {
        let session = AVAudioSession.sharedInstance()
        reportSessionReconfigured()
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

    private func listeningCategoryMatches() -> Bool {
        AVAudioSession.sharedInstance().category == .playback
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
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .allowBluetoothA2DP]
        if useSpeaker {
            options.insert(.defaultToSpeaker)
        }
        return options
    }

    /// Output graph only. Does not touch `inputNode`.
    private func buildPlaybackGraph() throws {
        let nodes = try makeOutputGraph()
        nodes.engine.prepare()
        try nodes.engine.start()
        try finishPlayback(voice: nodes.voice, beep: nodes.beep)
    }

    private func buildCaptureGraph() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord else {
            log.error("Refusing to open the microphone before playAndRecord is active")
            throw VoiceEngineError.failedToStart
        }
        let nodes = try makeOutputGraph()
        let engine = nodes.engine
        if !voiceProcessingDisabled {
            do {
                try engine.inputNode.setVoiceProcessingEnabled(true)
                voiceProcessingOn = true
                log.info("Voice processing on")
            } catch {
                voiceProcessingDisabled = true
                voiceProcessingOn = false
                log.error("Voice processing unavailable: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Touch inputNode only after the session is playAndRecord and active.
        guard let inputFormat = tapFormat(for: engine) else {
            throw VoiceEngineError.noInput
        }
        let ring = levelMeter
        let copies = MicCopies(format: inputFormat, frames: 8_192)
        engine.inputNode.installTap(onBus: 0, bufferSize: 256, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if self.waveArmed.load() != 0 {
                ring?.writeMic(buffer)
            }
            guard self.micOpen.withLock({ $0 }), buffer.frameLength > 0 else { return }
            guard let slot = copies.pushCopy(of: buffer) else { return }
            self.queue.async { [weak self] in
                guard let self else {
                    copies.release()
                    return
                }
                if self.shouldRun, let data = self.encode(slot), !data.isEmpty {
                    self.handlerLock.lock()
                    let handler = self.capture
                    self.handlerLock.unlock()
                    handler?(data)
                }
                copies.release()
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        try finishPlayback(voice: nodes.voice, beep: nodes.beep)
    }

    private func makeOutputGraph() throws -> (engine: AVAudioEngine, voice: AVAudioPlayerNode, beep: AVAudioPlayerNode) {
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        let voice = AVAudioPlayerNode()
        let beep = AVAudioPlayerNode()
        let keep = AVAudioPlayerNode()
        engine.attach(voice)
        engine.attach(beep)
        engine.attach(keep)
        let rate = session.sampleRate
        let sampleRate = rate > 0 ? rate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw VoiceEngineError.failedToStart
        }
        engine.connect(voice, to: engine.mainMixerNode, format: format)
        engine.connect(beep, to: engine.mainMixerNode, format: format)
        engine.connect(keep, to: engine.mainMixerNode, format: format)
        self.engine = engine
        self.voicePlayer = voice
        self.beepPlayer = beep
        self.keepAlivePlayer = keep
        self.playbackFormat = format
        self.tapInstalled = false
        self.voiceProcessingOn = false
        self.encoder = nil
        self.encoderInputKey = nil
        self.encoderScratch = nil
        self.wireScratch = nil
        self.burstStarted = false
        self.primeBuffers.removeAll()
        self.primeTimer?.cancel()
        self.primeTimer = nil
        engine.mainMixerNode.outputVolume = 1
        voice.volume = 1
        return (engine, voice, beep)
    }

    private func finishPlayback(voice: AVAudioPlayerNode, beep: AVAudioPlayerNode) throws {
        let render = voice.outputFormat(forBus: 0)
        if render.sampleRate > 0, render.channelCount > 0 {
            playbackFormat = render
        }
        guard let playbackFormat,
              let decoder = FormatConverter(from: Self.wireFormat, to: playbackFormat) else {
            throw VoiceEngineError.failedToStart
        }
        self.decoder = decoder
        voice.play()
        beep.play()
        armKeepAlive()
    }

    /// A looping silent buffer keeps the output IO running between transmissions.
    private func armKeepAlive() {
        guard let keep = keepAlivePlayer else { return }
        let output = keep.outputFormat(forBus: 0)
        let format = Self.isUsable(output) ? output : playbackFormat
        guard let format, format.sampleRate > 0 else { return }
        let frames = AVAudioFrameCount(max(256, format.sampleRate / 10))
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        silence.frameLength = frames
        keep.scheduleBuffer(silence, at: nil, options: .loops)
        if !keep.isPlaying { keep.play() }
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
        if let engine, tapInstalled || voiceProcessingOn {
            let input = engine.inputNode
            if tapInstalled {
                input.removeTap(onBus: 0)
            }
            tapInstalled = false
            engine.stop()
            if voiceProcessingOn {
                try? input.setVoiceProcessingEnabled(false)
            }
        } else {
            engine?.stop()
        }
        tapInstalled = false
        voiceProcessingOn = false
        captureArmed = false
        currentLevelMeter()?.hideMic()
        currentLevelMeter()?.hideRemote()
        engine?.stop()
        voicePlayer?.stop()
        beepPlayer?.stop()
        keepAlivePlayer?.stop()
        engine = nil
        voicePlayer = nil
        beepPlayer = nil
        keepAlivePlayer = nil
        decoder = nil
        encoder = nil
        encoderInputKey = nil
        encoderScratch = nil
        wireScratch = nil
        primeTimer?.cancel()
        primeTimer = nil
        primeBuffers.removeAll()
        burstStarted = false
        jitterTimerArmed = false
        lastAudioAt = .distantPast
        chirpPlaying = false
        playingClip = false
        clipGeneration += 1
        playbackGain = 1
    }

    private func currentLevelMeter() -> WaveRing? {
        levelMeterLock.lock()
        let meter = levelMeter
        levelMeterLock.unlock()
        return meter
    }

    private func encode(_ buffer: AVAudioPCMBuffer) -> Data? {
        let key = "\(buffer.format.sampleRate)|\(buffer.format.channelCount)|\(buffer.format.commonFormat.rawValue)|\(buffer.format.isInterleaved)"
        if encoder == nil || encoderInputKey != key {
            encoder = FormatConverter(from: buffer.format, to: Self.wireFormat)
            encoderInputKey = key
            encoderScratch = nil
        }
        if let converted = encoder?.convert(buffer, reusing: &encoderScratch),
           let channel = converted.floatChannelData,
           converted.frameLength > 0 {
            return PCM16.encodeLimited(channel[0], count: Int(converted.frameLength))
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
        return samples.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return Data() }
            return PCM16.encodeLimited(base, count: pointer.count)
        }
    }

    private func playIncomingOnQueue(_ data: Data) {
        guard shouldRun, let decoder, let player = voicePlayer, let expected = playbackFormat else { return }
        let bytes = data.prefix(64_000)
        guard let wire = wireBuffer(fromPCM16: bytes), let playback = decoder.convert(wire) else { return }
        currentLevelMeter()?.writeRemote(wire)
        guard abs(playback.format.sampleRate - expected.sampleRate) < 1,
              playback.format.channelCount == expected.channelCount else { return }
        if incomingMuted.withLock({ $0 }) { return }
        if playingClip {
            clipGeneration += 1
            playingClip = false
            player.stop()
            decoder.reset()
            burstStarted = false
            primeBuffers.removeAll()
            primeTimer?.cancel()
            primeTimer = nil
            jitterTimerArmed = false
            if !player.isPlaying { player.play() }
        }
        normalizePlayback(playback)
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
        let options: AVAudioPlayerNodeBufferOptions = chirpPlaying ? [] : [.interrupts]
        player.scheduleBuffer(buffer, at: nil, options: options)
        if !player.isPlaying { player.play() }
    }

    private func playRogerOnQueue() {
        guard shouldRun, let player = beepPlayer else { return }
        let output = player.outputFormat(forBus: 0)
        let format = output.sampleRate > 0 ? output : playbackFormat
        guard let format, let buffer = makeRoger(format: format) else { return }
        let options: AVAudioPlayerNodeBufferOptions = chirpPlaying ? [] : [.interrupts]
        player.scheduleBuffer(buffer, at: nil, options: options)
        if !player.isPlaying { player.play() }
    }

    /// One soft glide down, about 130 ms. Listeners hear it when talk ends.
    private func makeRoger(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return nil }
        let duration = 0.13
        let frames = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        let count = Int(frames)
        let channelCount = Int(format.channelCount)
        var phase = 0.0
        let startHz = 698.0
        let endHz = 349.0
        let fade = max(1, Int(sampleRate * 0.008))
        for index in 0..<count {
            let progress = Double(index) / Double(max(1, count - 1))
            let frequency = startHz + (endHz - startHz) * progress
            phase += 2 * Double.pi * frequency / sampleRate
            var amplitude = 0.16 * sin(phase)
            if index < fade { amplitude *= Double(index) / Double(fade) }
            let remaining = count - index
            if remaining < fade { amplitude *= Double(remaining) / Double(fade) }
            let sample = Float(amplitude)
            for channel in 0..<channelCount {
                channels[channel][index] = sample
            }
        }
        return buffer
    }

    private func playClipOnQueue(_ data: Data) {
        guard shouldRun, let decoder, let player = voicePlayer else { return }
        let pcm = data.prefix(45 * 32_000)
        let total = pcm.count - (pcm.count % 2)
        guard total >= 4 else { return }
        decoder.reset()
        clipGeneration += 1
        let token = clipGeneration
        playingClip = true
        player.stop()
        primeTimer?.cancel()
        primeTimer = nil
        primeBuffers.removeAll()
        burstStarted = false
        jitterTimerArmed = false
        let chunkBytes = 16_000
        var offset = 0
        var scheduled = false
        while offset < total {
            let end = min(offset + chunkBytes, total)
            let slice = pcm.subdata(in: offset..<end)
            offset = end
            guard let wire = wireBuffer(fromPCM16: slice), let playback = decoder.convert(wire) else { continue }
            normalizePlayback(playback)
            if offset >= total {
                player.scheduleBuffer(playback, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    self?.queue.async {
                        guard let self, self.clipGeneration == token else { return }
                        self.playingClip = false
                    }
                }
            } else {
                player.scheduleBuffer(playback)
            }
            scheduled = true
        }
        if scheduled {
            if !player.isPlaying { player.play() }
        } else {
            playingClip = false
        }
    }

    private func stopPlaybackClipOnQueue() {
        guard playingClip, let player = voicePlayer else { return }
        clipGeneration += 1
        playingClip = false
        player.stop()
        if !player.isPlaying { player.play() }
    }

    /// Slow leveler for playback only. The waveform still reads the raw wire buffer.
    private func normalizePlayback(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return }
        let user = listenGain.withLock { $0 }
        guard frames > 8 else {
            applyListenGain(channels, frames: frames, channelCount: channelCount, level: 1, user: user)
            return
        }
        let step = max(1, frames / 240)
        var sum: Float = 0
        var counted = 0
        var index = 0
        while index < frames {
            let sample = channels[0][index]
            sum += sample * sample
            counted += 1
            index += step
        }
        let rms = sqrt(sum / Float(max(1, counted)))
        var desired: Float = 1
        if rms >= 0.012 {
            desired = min(3.5, max(0.5, 0.1 / rms))
        }
        let alpha: Float = desired > playbackGain ? 0.35 : 0.12
        playbackGain += (desired - playbackGain) * alpha
        let level = playbackGain
        applyListenGain(channels, frames: frames, channelCount: channelCount, level: level, user: user)
    }

    private func applyListenGain(
        _ channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        frames: Int,
        channelCount: Int,
        level: Float,
        user: Float
    ) {
        let gain = level * user
        if abs(level - 1) < 0.03 && user > 0.995 { return }
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frames {
                var sample = samples[frame] * gain
                if sample > 0.98 { sample = 0.98 }
                if sample < -0.98 { sample = -0.98 }
                samples[frame] = sample
            }
        }
    }

    /// Two short rising tones, about 110 ms, at a moderate level.
    private func makeChirp(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let sampleRate = format.sampleRate
        guard sampleRate > 0 else { return nil }
        let first = 0.050
        let gap = 0.010
        let second = 0.052
        let frames = AVAudioFrameCount(sampleRate * (first + gap + second))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        let channelCount = Int(format.channelCount)
        let firstFrames = Int(sampleRate * first)
        let secondStart = Int(sampleRate * (first + gap))
        for index in 0..<Int(frames) {
            var amplitude = 0.0
            if index < firstFrames {
                amplitude = tone(index: index, count: firstFrames, frequency: 784, sampleRate: sampleRate)
            } else if index >= secondStart {
                let local = index - secondStart
                let count = Int(frames) - secondStart
                amplitude = tone(index: local, count: count, frequency: 1175, sampleRate: sampleRate)
            }
            let sample = Float(amplitude)
            for channel in 0..<channelCount {
                channels[channel][index] = sample
            }
        }
        return buffer
    }

    private func tone(index: Int, count: Int, frequency: Double, sampleRate: Double) -> Double {
        guard count > 1 else { return 0 }
        let time = Double(index) / sampleRate
        var amplitude = 0.22 * sin(2 * Double.pi * frequency * time)
        let fade = max(1, min(count / 4, Int(sampleRate * 0.004)))
        if index < fade { amplitude *= Double(index) / Double(fade) }
        let remaining = count - index
        if remaining < fade { amplitude *= Double(remaining) / Double(fade) }
        return amplitude
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

    /// Reused across packets. Callers finish reading it before the next packet.
    private func wireBuffer(fromPCM16 data: Data) -> AVAudioPCMBuffer? {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0 else { return nil }
        let frames = AVAudioFrameCount(count)
        let buffer: AVAudioPCMBuffer
        if let wireScratch, wireScratch.frameCapacity >= frames {
            buffer = wireScratch
        } else {
            guard let created = AVAudioPCMBuffer(pcmFormat: Self.wireFormat, frameCapacity: frames) else { return nil }
            wireScratch = created
            buffer = created
        }
        buffer.frameLength = frames
        guard let channel = buffer.floatChannelData else { return nil }
        let dest = channel[0]
        data.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            guard let source = ints.baseAddress else { return }
            for index in 0..<count {
                dest[index] = Float(source[index]) / 32_768
            }
        }
        return buffer
    }

    @discardableResult
    private func applyOutputRoute(force: Bool = false) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let hasExternal = session.currentRoute.outputs.contains { Self.externalPorts.contains($0.portType) }
        let desired: AVAudioSession.PortOverride = (hasExternal || !useSpeaker) ? .none : .speaker
        var changed = false
        if outputOptionsNeedUpdate(session) {
            reportSessionReconfigured()
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

    /// A cold playback session is left alone. A warm `playAndRecord` graph
    /// still picks up speaker and Bluetooth option changes while the gate is closed.
    private func outputOptionsNeedUpdate(_ session: AVAudioSession) -> Bool {
        guard session.category == .playAndRecord else { return false }
        let options = session.categoryOptions
        if options.contains(.allowBluetoothHFP) == false { return true }
        if options.contains(.allowBluetoothA2DP) == false { return true }
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
            restartAudio(.interrupted)
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
                self.restartAudio(.routeChanged)
            } else {
                self.refreshRouteAfterChange()
            }
        }
    }

    private func refreshRouteAfterChange() {
        let refresh: () -> Void = { [weak self] in
            guard let self else { return }
            guard self.queue.sync(execute: { self.shouldRun }) else { return }
            let holding = self.micOpen.withLock { $0 } || self.releaseTail != nil
            let wants = self.queue.sync { self.wantsCapture }
            if self.appIsActive || holding || wants {
                if self.warmGraphReady() {
                    self.applyOutputRoute()
                    return
                }
                do {
                    try self.startCaptureOnMain(force: true)
                } catch {
                    self.log.error("Warm route rebuild failed: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            guard !self.listeningCategoryMatches() else { return }
            try? self.startListeningOnMain(force: true)
        }
        if Thread.isMainThread {
            refresh()
        } else {
            DispatchQueue.main.async(execute: refresh)
        }
    }

    private func handleMediaReset() {
        restartAudio(.mediaReset)
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

    private func reportFailure(_ alert: AudioAlert) {
        DispatchQueue.main.async { [weak self] in
            self?.onFailure?(alert)
        }
    }
}

/// Preallocated mic copies so the input tap never allocates.
private final class MicCopies: @unchecked Sendable {
    private struct Cursor: Sendable {
        var write = 0
        var read = 0
    }

    private let slots: [AVAudioPCMBuffer]
    private let state = OSAllocatedUnfairLock(initialState: Cursor())

    init(format: AVAudioFormat, frames: AVAudioFrameCount, count: Int = 8) {
        var made: [AVAudioPCMBuffer] = []
        made.reserveCapacity(count)
        for _ in 0..<count {
            if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
                made.append(buffer)
            }
        }
        slots = made
    }

    func pushCopy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        state.withLock { cursor in
            if slots.isEmpty || cursor.write - cursor.read >= slots.count { return nil }
            let dest = slots[cursor.write % slots.count]
            guard Self.copy(buffer, into: dest) else { return nil }
            cursor.write += 1
            return dest
        }
    }

    func release() {
        state.withLock { cursor in
            if cursor.read < cursor.write {
                cursor.read += 1
            }
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer, into dest: AVAudioPCMBuffer) -> Bool {
        let frames = buffer.frameLength
        guard frames > 0, frames <= dest.frameCapacity else { return false }
        dest.frameLength = frames
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(dest.mutableAudioBufferList)
        guard source.count == destination.count else { return false }
        for index in source.indices {
            guard let src = source[index].mData, let dst = destination[index].mData else { continue }
            let byteCount = min(Int(source[index].mDataByteSize), Int(destination[index].mDataByteSize))
            guard byteCount > 0 else { continue }
            dst.copyMemory(from: src, byteCount: byteCount)
        }
        return true
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
        var scratch: AVAudioPCMBuffer?
        return convert(input, reusing: &scratch)
    }

    /// `reusing` keeps the uplink buffer. Playback must pass a fresh slot so a queued buffer is not overwritten.
    func convert(_ input: AVAudioPCMBuffer, reusing scratch: inout AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        guard input.frameLength > 0 else { return nil }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let estimate = Double(input.frameLength) * ratio
        let capacity = AVAudioFrameCount(max(32.0, estimate.rounded(.up) + 32.0))
        let output: AVAudioPCMBuffer
        if let scratch, scratch.frameCapacity >= capacity {
            output = scratch
            output.frameLength = 0
        } else {
            guard let created = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
                return nil
            }
            scratch = created
            output = created
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
