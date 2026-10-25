import AVFoundation
import Combine
import Foundation
import MediaPlayer
import Security

@MainActor
final class WalkieSession: ObservableObject {
    static let defaultServerURL = "wss://walkie-bc0z.onrender.com"

    @Published var name: String
    /// Display name of the selected talk group. Kept so older saved channels still load.
    @Published var room: String
    @Published var serverURL: String
    @Published var groups: [WalkieGroup]
    @Published var talkGroup: String
    @Published private(set) var linkState: LinkState = .disconnected
    @Published private(set) var statusText = "Ikke tilkoblet"
    @Published private(set) var membersByRoom: [String: [RoomMember]] = [:]
    @Published private(set) var selfID = ""
    @Published private(set) var joinProblems: [String: String] = [:]
    @Published private(set) var talkers: [Talker] = []
    @Published private(set) var isTalking = false
    @Published private(set) var audioReady = false
    @Published var errorMessage: String?
    @Published private(set) var suggestsSettings = false
    @Published private(set) var hasConnectedOnce = false
    @Published var speakerphone: Bool

    var canTransmit: Bool {
        linkState == .connected && audioReady
    }

    var speakerLine: String {
        var namesByRoom: [String: [String]] = [:]
        var order: [String] = []
        for talker in talkers {
            if namesByRoom[talker.room] == nil {
                order.append(talker.room)
                namesByRoom[talker.room] = []
            }
            namesByRoom[talker.room, default: []].append(talker.name)
        }
        if isTalking, !talkGroup.isEmpty, !name.isEmpty, !localTalkerListed {
            if namesByRoom[talkGroup] == nil {
                order.append(talkGroup)
            }
            namesByRoom[talkGroup, default: []].append(name)
        }
        let parts = order.compactMap { roomID -> String? in
            guard let names = namesByRoom[roomID], !names.isEmpty else { return nil }
            let label = groups.first { $0.id == roomID }?.name ?? roomID
            return names.joined(separator: ", ") + " i " + label
        }
        if parts.isEmpty { return "" }
        return parts.joined(separator: " · ") + " snakker"
    }

    var centerStatus: String {
        if linkState != .connected { return statusText }
        let count = onlineMembers(in: talkGroup).count
        if count == 0 { return "Ingen pålogget" }
        if count == 1 { return "1 pålogget" }
        return "\(count) pålogget"
    }

    func joinProblem(for groupID: String) -> String {
        joinProblems[groupID] ?? ""
    }

    func onlineMembers(in groupID: String) -> [OnlineMember] {
        var list = membersByRoom[groupID] ?? []
        for talker in talkers where talker.room == groupID && !list.contains(where: { $0.id == talker.id }) {
            list.append(RoomMember(id: talker.id, name: talker.name))
        }
        if isTalking, groupID == talkGroup, !name.isEmpty, !list.contains(where: { $0.id == localMemberID }) {
            list.append(RoomMember(id: localMemberID, name: name))
        }
        return list.map { member in
            let remote = talkers.contains { $0.id == member.id && $0.room == groupID }
            let local = isTalking && groupID == talkGroup && member.id == localMemberID
            let legacy = isTalking && groupID == talkGroup && selfID.isEmpty && member.name == name
            return OnlineMember(id: member.id, name: member.name, talking: remote || local || legacy)
        }
    }

    func presenceCaption(for groupID: String) -> String {
        guard linkState == .connected else { return "" }
        if !joinProblem(for: groupID).isEmpty { return "" }
        if onlineMembers(in: groupID).isEmpty { return "Ingen pålogget" }
        return ""
    }

    private var localMemberID: String {
        selfID.isEmpty ? "local" : selfID
    }

    private var localTalkerListed: Bool {
        if selfID.isEmpty {
            return talkers.contains { $0.room == talkGroup && $0.name == name }
        }
        return talkers.contains { $0.room == talkGroup && $0.id == selfID }
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
        var storedGroups = Self.loadGroups(defaults)
        var storedTalk = defaults.string(forKey: Key.talkGroup) ?? ""
        if storedGroups.isEmpty {
            let migrated = Self.clip(storedRoom, limit: 40).lowercased()
            if !migrated.isEmpty {
                storedGroups = [
                    WalkieGroup(id: migrated, name: storedRoom, listen: true, locked: false, setsPassword: false)
                ]
                storedTalk = migrated
            }
        }
        storedGroups = storedGroups.map { group in
            var copy = group
            if GroupPasswordStore.load(account: group.id) != nil {
                copy.locked = true
            }
            return copy
        }
        if !storedGroups.contains(where: { $0.id == storedTalk }) {
            storedTalk = storedGroups.first?.id ?? ""
        }
        name = storedName
        groups = storedGroups
        talkGroup = storedTalk
        room = storedGroups.first { $0.id == storedTalk }?.name ?? storedRoom
        serverURL = storedServer.isEmpty ? Self.defaultServerURL : storedServer
        speakerphone = defaults.object(forKey: Key.speakerphone) as? Bool ?? true
        engine.setSpeakerphone(speakerphone)
        engine.activateForSystemVolume()

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
        engine.onSessionReconfigured = { [weak self] in
            Task { @MainActor in
                self?.volumeButtons.noteSessionReconfigured()
            }
        }
    }

    func savePreferences() {
        defaults.set(name, forKey: Key.name)
        defaults.set(room, forKey: Key.room)
        defaults.set(serverURL, forKey: Key.server)
        saveGroups()
    }

    @discardableResult
    func createGroup(named rawName: String, password rawPassword: String) -> Bool {
        upsert(named: rawName, password: rawPassword, creating: true)
    }

    @discardableResult
    func joinGroup(named rawName: String, password rawPassword: String) -> Bool {
        upsert(named: rawName, password: rawPassword, creating: false)
    }

    func setListening(_ id: String, _ listen: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].listen = listen
        saveGroups()
        pushMembership()
    }

    func selectTalk(_ id: String) {
        guard groups.contains(where: { $0.id == id }) else { return }
        talkGroup = id
        syncRoomName()
        saveGroups()
        pushMembership()
    }

    func removeGroup(_ id: String) {
        groups.removeAll { $0.id == id }
        GroupPasswordStore.delete(account: id)
        membersByRoom[id] = nil
        joinProblems[id] = nil
        let leaving = talkers.filter { $0.room == id }
        for talker in leaving {
            removeTalker(id: talker.id, room: talker.room)
        }
        if talkGroup == id {
            talkGroup = groups.first?.id ?? ""
            syncRoomName()
        }
        saveGroups()
        pushMembership()
    }

    func saveSpeakerphone() {
        defaults.set(speakerphone, forKey: Key.speakerphone)
        engine.setSpeakerphone(speakerphone)
    }

    /// Audio session plus the key-window volume slider. Safe to call again
    /// when the scene becomes active.
    func prepareVolumeHUD() {
        engine.activateForSystemVolume()
        volumeButtons.installKeyWindowVolumeSlider(session: self)
        Task { @MainActor in
            self.volumeButtons.installKeyWindowVolumeSlider(session: self)
        }
    }

    func releaseIdleVolumeSession() {
        engine.deactivateIdleSessionIfNeeded()
    }

    func dismissError() {
        errorMessage = nil
        suggestsSettings = false
    }

    func connect() {
        guard linkState == .disconnected else { return }
        let trimmedName = Self.clip(name, limit: 30)
        guard !trimmedName.isEmpty else {
            suggestsSettings = false
            errorMessage = "Skriv inn navn."
            return
        }
        guard !groups.isEmpty else {
            suggestsSettings = false
            errorMessage = "Opprett eller bli med i en gruppe."
            return
        }
        if !groups.contains(where: { $0.id == talkGroup }) {
            talkGroup = groups[0].id
        }
        guard let url = Self.normalizeServerURL(serverURL) else {
            suggestsSettings = false
            errorMessage = "Serveradressen må være ws:// eller wss://."
            return
        }
        name = trimmedName
        syncRoomName()
        serverURL = url.absoluteString
        savePreferences()
        activeURL = url
        shouldReconnect = true
        membersByRoom = [:]
        selfID = ""
        talkers = []
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
        clearPresence()
        linkState = .disconnected
        statusText = "Ikke tilkoblet"
        prepareVolumeHUD()
    }

    func beginTransmitting() {
        transmitter.beginTransmitting()
    }

    /// Stops sending. Does not change the audio session category or mode.
    func endTransmitting() {
        transmitter.endTransmitting()
    }

    /// Volume-up holds transmitting only while the caller reports that the
    /// app is in the foreground and the channel is connected.
    func setVolumeButtonMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            volumeButtons.start { [weak self] holding in
                guard let self else { return }
                if holding {
                    self.beginTransmitting()
                } else {
                    self.endTransmitting()
                }
            }
        } else {
            volumeButtons.stop()
        }
    }

    func attachSystemVolumeView(_ view: MPVolumeView) {
        volumeButtons.attach(view)
    }

    func detachSystemVolumeView(_ view: MPVolumeView) {
        volumeButtons.detach(view)
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
            prepareVolumeHUD()
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
        clearPresence()
        linkState = .disconnected
        statusText = "Ikke tilkoblet"
        suggestsSettings = settings
        errorMessage = message
        prepareVolumeHUD()
    }

    private func handleOpen() {
        hasConnectedOnce = true
        linkState = .connected
        statusText = "Tilkoblet"
        pushMembership()
    }

    private func handleClose() {
        let somebodyTalking = !talkers.isEmpty
        talkers.removeAll()
        membersByRoom = [:]
        selfID = ""
        if somebodyTalking {
            engine.playTalkBoundaryBeep(isStart: false)
        }
        engine.markTalkBurstEnded()
        endTransmitting()
        guard shouldReconnect else { return }
        linkState = .reconnecting
        statusText = "Frakoblet – prøver igjen…"
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
        case .users(let room, let members, let selfID):
            let key = room.isEmpty ? talkGroup : room
            guard !key.isEmpty else { return }
            if !selfID.isEmpty { self.selfID = selfID }
            membersByRoom[key] = members
            if includesSelf(members) {
                joinProblems[key] = nil
            } else if linkState == .connected {
                joinProblems[key] = "Ikke med i gruppen"
            }
            let gone = talkers.filter { talker in
                guard talker.room == key else { return false }
                if members.contains(where: { $0.id == talker.id }) { return false }
                if talker.id == talker.name && members.contains(where: { $0.name == talker.name }) { return false }
                return true
            }
            for talker in gone {
                removeTalker(id: talker.id, room: talker.room)
            }
        case .talkStarted(let name, let room, let id):
            addTalker(id: id, name: name, room: room.isEmpty ? talkGroup : room)
        case .talkStopped(let name, let room, let id):
            removeTalker(id: id.isEmpty ? name : id, room: room.isEmpty ? talkGroup : room)
        case .rejected(let room, let message):
            let text = message.isEmpty ? "Feil passord" : message
            if !room.isEmpty {
                joinProblems[room] = text
            }
            let label = groups.first { $0.id == room }?.name ?? room
            if label.isEmpty {
                errorMessage = text
            } else {
                errorMessage = "\(label): \(text)"
            }
        }
    }

    private func includesSelf(_ members: [RoomMember]) -> Bool {
        if !selfID.isEmpty, members.contains(where: { $0.id == selfID }) { return true }
        if selfID.isEmpty, members.contains(where: { $0.name == name }) { return true }
        return false
    }

    private func clearPresence() {
        membersByRoom = [:]
        selfID = ""
        talkers = []
        joinProblems = [:]
    }

    private func addTalker(id: String, name: String, room: String) {
        guard !room.isEmpty, !name.isEmpty else { return }
        let key = id.isEmpty ? name : id
        guard !talkers.contains(where: { $0.id == key && $0.room == room }) else { return }
        talkers.append(Talker(id: key, name: name, room: room))
        engine.playTalkBoundaryBeep(isStart: true)
    }

    private func removeTalker(id: String, room: String) {
        guard let index = talkers.firstIndex(where: { $0.id == id && $0.room == room }) else { return }
        talkers.remove(at: index)
        engine.playTalkBoundaryBeep(isStart: false)
        if talkers.isEmpty {
            engine.markTalkBurstEnded()
        }
    }

    @discardableResult
    private func upsert(named rawName: String, password rawPassword: String, creating: Bool) -> Bool {
        let label = Self.clip(rawName, limit: 40)
        let id = label.lowercased()
        guard !id.isEmpty else {
            suggestsSettings = false
            errorMessage = "Skriv et gruppenavn."
            return false
        }
        let secret = String(rawPassword.prefix(80))
        if let index = groups.firstIndex(where: { $0.id == id }) {
            groups[index].name = label
            groups[index].listen = true
            if !secret.isEmpty {
                GroupPasswordStore.save(secret, account: id)
                groups[index].locked = true
                if creating {
                    groups[index].setsPassword = true
                }
            } else if creating {
                groups[index].setsPassword = false
            }
        } else {
            let storesSecret = !secret.isEmpty
            if storesSecret {
                GroupPasswordStore.save(secret, account: id)
            }
            groups.append(
                WalkieGroup(
                    id: id,
                    name: label,
                    listen: true,
                    locked: storesSecret,
                    setsPassword: creating && storesSecret
                )
            )
        }
        if creating || talkGroup.isEmpty {
            talkGroup = id
        }
        syncRoomName()
        saveGroups()
        pushMembership()
        return true
    }

    private func pushMembership() {
        guard linkState == .connected else { return }
        let wires = groups.map { group in
            GroupWire(
                room: group.id,
                password: GroupPasswordStore.load(account: group.id) ?? "",
                create: group.setsPassword,
                listen: group.listen
            )
        }
        socket.sendGroups(name: name, talk: talkGroup, groups: wires)
        if !talkGroup.isEmpty {
            let password = GroupPasswordStore.load(account: talkGroup) ?? ""
            socket.sendJoin(name: name, room: talkGroup, password: password)
        }
    }

    private func syncRoomName() {
        room = groups.first { $0.id == talkGroup }?.name ?? ""
    }

    private func saveGroups() {
        if let data = try? JSONEncoder().encode(groups) {
            defaults.set(data, forKey: Key.groups)
        }
        defaults.set(talkGroup, forKey: Key.talkGroup)
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
        static let speakerphone = "walkie.speakerphone"
        static let groups = "walkie.groups"
        static let talkGroup = "walkie.talkGroup"
    }

    private static func loadGroups(_ defaults: UserDefaults) -> [WalkieGroup] {
        guard let data = defaults.data(forKey: Key.groups),
              let decoded = try? JSONDecoder().decode([WalkieGroup].self, from: data) else { return [] }
        return decoded
    }
}

extension WalkieSession: ChannelSignaling {
    func sendTalkStart() {
        socket.sendStart(room: talkGroup)
    }

    func sendTalkStop() {
        socket.sendStop(room: talkGroup)
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

struct WalkieGroup: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var listen: Bool
    var locked: Bool
    var setsPassword: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, listen, locked, setsPassword
    }

    init(id: String, name: String, listen: Bool, locked: Bool, setsPassword: Bool) {
        self.id = id
        self.name = name
        self.listen = listen
        self.locked = locked
        self.setsPassword = setsPassword
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        listen = try container.decodeIfPresent(Bool.self, forKey: .listen) ?? true
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        setsPassword = try container.decodeIfPresent(Bool.self, forKey: .setsPassword) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(listen, forKey: .listen)
        try container.encode(locked, forKey: .locked)
        try container.encode(setsPassword, forKey: .setsPassword)
    }
}

struct RoomMember: Codable, Equatable, Identifiable {
    var id: String
    var name: String
}

struct Talker: Equatable, Identifiable {
    var id: String
    var name: String
    var room: String
}

struct OnlineMember: Identifiable, Equatable {
    var id: String
    var name: String
    var talking: Bool
}

enum GroupPasswordStore {
    private static let service = "com.skuyng.walkie.group"

    static func save(_ password: String, account: String) {
        guard !account.isEmpty else { return }
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updated: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, updated as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(insert as CFDictionary, nil)
        }
    }

    static func load(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        guard !account.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
