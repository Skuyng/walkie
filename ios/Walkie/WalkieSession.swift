import AVFoundation
import Combine
import Foundation

@MainActor
final class WalkieSession: ObservableObject {
    static let defaultServerURL = "wss://walkie-bc0z.onrender.com"

    @Published var name: String
    @Published var room: String
    @Published var serverURL: String
    @Published private(set) var linkState: LinkState = .disconnected
    @Published private(set) var statusText = "Ikke tilkoblet"
    @Published private(set) var users: [String] = []
    @Published private(set) var speakers: [String] = []
    @Published private(set) var isTalking = false
    @Published private(set) var audioReady = false
    @Published var errorMessage: String?
    @Published private(set) var suggestsSettings = false
    @Published private(set) var hasConnectedOnce = false

    var canTransmit: Bool {
        linkState == .connected && audioReady
    }

    var usersLine: String {
        if users.isEmpty { return "I kanalen: …" }
        return "I kanalen: " + users.joined(separator: ", ")
    }

    var speakerLine: String {
        if speakers.isEmpty { return "" }
        return "🔊 " + speakers.joined(separator: ", ") + " snakker"
    }

    private let defaults = UserDefaults.standard
    private let engine = VoiceEngine()
    private let socket = WalkieSocket()
    private let transmitter = HoldToTalkTransmitter()
    private let volumeButtons = VolumeButtonMonitor()
    private var activeURL: URL?
    private var shouldReconnect = false
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let storedName = defaults.string(forKey: Key.name) ?? ""
        let storedRoom = defaults.string(forKey: Key.room) ?? ""
        let storedServer = defaults.string(forKey: Key.server) ?? ""
        name = storedName
        room = storedRoom
        serverURL = storedServer.isEmpty ? Self.defaultServerURL : storedServer

        transmitter.signaling = self
        transmitter.onChange = { [weak self] talking in
            self?.isTalking = talking
        }
        socket.onOpen = { [weak self] in
            Task { @MainActor in self?.handleOpen() }
        }
        socket.onClose = { [weak self] _ in
            Task { @MainActor in self?.handleClose() }
        }
        socket.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        socket.onAudio = { [weak self] data in
            self?.engine.playIncoming(data)
        }
        engine.setCaptureHandler { [weak self] data in
            self?.socket.send(audio: data)
        }
        engine.onFailure = { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.audioReady = false
                let denied = AVAudioApplication.shared.recordPermission != .granted
                self.errorMessage = denied
                    ? VoiceEngineError.microphoneDenied.localizedDescription
                    : message
                self.suggestsSettings = denied
            }
        }
        engine.onInterrupted = { [weak self] in
            Task { @MainActor in self?.endTransmitting() }
        }
    }

    func savePreferences() {
        defaults.set(name, forKey: Key.name)
        defaults.set(room, forKey: Key.room)
        defaults.set(serverURL, forKey: Key.server)
    }

    func dismissError() {
        errorMessage = nil
        suggestsSettings = false
    }

    func connect() {
        guard linkState == .disconnected else { return }
        let trimmedName = Self.clip(name, limit: 30)
        let trimmedRoom = Self.clip(room, limit: 40).lowercased()
        guard !trimmedName.isEmpty, !trimmedRoom.isEmpty else {
            suggestsSettings = false
            errorMessage = "Skriv inn navn og kanalkode."
            return
        }
        guard let url = Self.normalizeServerURL(serverURL) else {
            suggestsSettings = false
            errorMessage = "Serveradressen må være ws:// eller wss://."
            return
        }
        name = trimmedName
        room = trimmedRoom
        serverURL = url.absoluteString
        savePreferences()
        activeURL = url
        shouldReconnect = true
        users = []
        speakers = []
        linkState = .connecting
        statusText = "Kobler til…"
        dismissError()
        connectTask?.cancel()
        connectTask = Task { await self.startAudioAndSocket() }
    }

    func disconnect() {
        shouldReconnect = false
        connectTask?.cancel()
        reconnectTask?.cancel()
        setVolumeButtonMonitoringEnabled(false)
        endTransmitting()
        socket.close()
        engine.stop()
        audioReady = false
        hasConnectedOnce = false
        users = []
        speakers = []
        linkState = .disconnected
        statusText = "Ikke tilkoblet"
    }

    func beginTransmitting() {
        transmitter.beginTransmitting()
    }

    func endTransmitting() {
        transmitter.endTransmitting()
    }

    /// Volume-up toggles transmitting only while the caller reports that the
    /// app is in the foreground and the channel is connected.
    func setVolumeButtonMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            volumeButtons.start { [weak self] in
                self?.toggleFromVolumeButton()
            }
        } else {
            volumeButtons.stop()
        }
    }

    private func toggleFromVolumeButton() {
        guard linkState == .connected else { return }
        if isTalking {
            endTransmitting()
        } else {
            beginTransmitting()
        }
    }

    func resumeAudioIfNeeded() {
        guard shouldReconnect else { return }
        engine.ensureRunning()
    }

    private func startAudioAndSocket() async {
        let granted = await requestMicrophoneAccess()
        guard shouldReconnect, !Task.isCancelled else { return }
        guard granted else {
            failBeforeSession(VoiceEngineError.microphoneDenied.localizedDescription, settings: true)
            return
        }
        do {
            try engine.start()
        } catch VoiceEngineError.microphoneDenied {
            failBeforeSession(VoiceEngineError.microphoneDenied.localizedDescription, settings: true)
            return
        } catch let error as VoiceEngineError {
            let denied = AVAudioApplication.shared.recordPermission != .granted
            failBeforeSession(error.localizedDescription, settings: denied)
            return
        } catch {
            failBeforeSession("Fikk ikke startet lyden.", settings: false)
            return
        }
        guard shouldReconnect, !Task.isCancelled else {
            engine.stop()
            audioReady = false
            return
        }
        audioReady = true
        guard let activeURL else { return }
        socket.connect(url: activeURL)
    }

    /// Always asks before the engine starts. A granted or denied answer returns
    /// immediately; the system sheet is shown only when the choice is still open.
    private func requestMicrophoneAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func failBeforeSession(_ message: String, settings: Bool) {
        shouldReconnect = false
        audioReady = false
        engine.stop()
        linkState = .disconnected
        statusText = "Ikke tilkoblet"
        suggestsSettings = settings
        errorMessage = message
    }

    private func handleOpen() {
        hasConnectedOnce = true
        linkState = .connected
        statusText = "🟢 Tilkoblet"
        socket.sendJoin(name: name, room: room)
    }

    private func handleClose() {
        let somebodyTalking = !speakers.isEmpty
        speakers.removeAll()
        if somebodyTalking {
            engine.playTalkBoundaryBeep(isStart: false)
        }
        engine.markTalkBurstEnded()
        endTransmitting()
        guard shouldReconnect else { return }
        linkState = .reconnecting
        statusText = "🔴 Frakoblet – prøver igjen…"
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.shouldReconnect, !Task.isCancelled, let url = self.activeURL else { return }
            self.statusText = "Kobler til…"
            self.socket.connect(url: url)
        }
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .users(let names):
            users = names
            let gone = speakers.filter { !names.contains($0) }
            for name in gone {
                removeSpeaker(name)
            }
        case .talkStarted(let name):
            addSpeaker(name)
        case .talkStopped(let name):
            removeSpeaker(name)
        }
    }

    private func addSpeaker(_ name: String) {
        guard !speakers.contains(name) else { return }
        speakers.append(name)
        engine.playTalkBoundaryBeep(isStart: true)
    }

    private func removeSpeaker(_ name: String) {
        guard let index = speakers.firstIndex(of: name) else { return }
        speakers.remove(at: index)
        engine.playTalkBoundaryBeep(isStart: false)
        if speakers.isEmpty {
            engine.markTalkBurstEnded()
        }
    }

    private static func clip(_ text: String, limit: Int) -> String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    static func normalizeServerURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = defaultServerURL }
        let lower = text.lowercased()
        if lower.hasPrefix("https://") {
            text = "wss://" + text.dropFirst("https://".count)
        } else if lower.hasPrefix("http://") {
            text = "ws://" + text.dropFirst("http://".count)
        } else if !text.contains("://") {
            text = "wss://" + text
        }
        guard let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              let host = url.host,
              !host.isEmpty else { return nil }
        return url
    }

    private enum Key {
        static let name = "walkie.name"
        static let room = "walkie.room"
        static let server = "walkie.serverURL"
    }
}

extension WalkieSession: ChannelSignaling {
    func sendTalkStart() {
        socket.sendStart()
    }

    func sendTalkStop() {
        socket.sendStop()
    }

    func setMicrophoneOpen(_ open: Bool) {
        engine.setMicrophoneOpen(open)
    }
}

enum LinkState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}
