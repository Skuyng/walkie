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
    @Published private(set) var signedIn = false
    @Published private(set) var restoringSession = false
    @Published private(set) var accountUsername = ""
    @Published private(set) var invites: [WalkieInvite] = []
    @Published private(set) var requests: [WalkieRequest] = []

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
    private var accountToken: String?
    private var pendingAuth: PendingAuth?
    private var keepAccount = false
    private var socketOpen = false
    private var socketReady = false
    private var preferTalk: String?

    private enum PendingAuth {
        case signup(user: String, display: String, password: String)
        case login(user: String, password: String)
    }

    init() {
        let defaults = UserDefaults.standard
        let storedName = defaults.string(forKey: Key.name) ?? ""
        let storedRoom = defaults.string(forKey: Key.room) ?? ""
        let storedServer = defaults.string(forKey: Key.server) ?? ""
        var storedGroups = Self.loadGroups(defaults)
        var storedTalk = defaults.string(forKey: Key.talkGroup) ?? ""
        if !storedGroups.contains(where: { $0.id == storedTalk }) {
            storedTalk = storedGroups.first?.id ?? ""
        }
        name = storedName
        groups = storedGroups
        talkGroup = storedTalk
        room = storedGroups.first { $0.id == storedTalk }?.name ?? storedRoom
        serverURL = storedServer.isEmpty ? Self.defaultServerURL : storedServer
        accountUsername = defaults.string(forKey: Key.username) ?? ""
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
        if let token = AccountTokenStore.load(), !token.isEmpty {
            accountToken = token
            keepAccount = true
            restoringSession = true
            statusText = "Logger inn…"
            linkState = .connecting
            openAccountSocket()
        }
    }

    func savePreferences() {
        defaults.set(name, forKey: Key.name)
        defaults.set(room, forKey: Key.room)
        defaults.set(serverURL, forKey: Key.server)
        saveGroups()
    }

    func signUp(username rawUser: String, displayName rawDisplay: String, password rawPassword: String) {
        let user = Self.normalizeUsername(rawUser)
        let display = Self.clip(rawDisplay, limit: 30)
        let password = String(rawPassword.prefix(80))
        guard Self.validUsername(user) else {
            suggestsSettings = false
            errorMessage = "Brukernavnet må være 3–20 tegn (a–z, 0–9)."
            return
        }
        guard !display.isEmpty else {
            suggestsSettings = false
            errorMessage = "Skriv et navn."
            return
        }
        guard password.count >= 4 else {
            suggestsSettings = false
            errorMessage = "Passordet må ha minst 4 tegn."
            return
        }
        name = display
        pendingAuth = .signup(user: user, display: display, password: password)
        savePreferences()
        dismissError()
        flushOrOpen()
    }

    func logIn(username rawUser: String, password rawPassword: String) {
        let user = Self.normalizeUsername(rawUser)
        let password = String(rawPassword.prefix(80))
        guard Self.validUsername(user) else {
            suggestsSettings = false
            errorMessage = "Brukernavnet må være 3–20 tegn (a–z, 0–9)."
            return
        }
        guard password.count >= 4 else {
            suggestsSettings = false
            errorMessage = "Passordet må ha minst 4 tegn."
            return
        }
        pendingAuth = .login(user: user, password: password)
        dismissError()
        flushOrOpen()
    }

    func logOut() {
        keepAccount = false
        shouldReconnect = false
        pendingAuth = nil
        restoringSession = false
        accountToken = nil
        AccountTokenStore.delete()
        signedIn = false
        accountUsername = ""
        defaults.removeObject(forKey: Key.username)
        groups = []
        invites = []
        requests = []
        talkGroup = ""
        room = ""
        preferTalk = nil
        saveGroups()
        if socketOpen {
            socket.sendLogout { [weak self] in
                Task { @MainActor in self?.disconnect() }
            }
        } else {
            disconnect()
        }
    }

    func cancelAccountConnect() {
        pendingAuth = nil
        restoringSession = false
        keepAccount = false
        shouldReconnect = false
        socket.close()
        socketOpen = false
        socketReady = false
        linkState = .disconnected
        statusText = "Ikke tilkoblet"
    }

    @discardableResult
    func createGroup(named rawName: String, password rawPassword: String) -> Bool {
        let label = Self.clip(rawName, limit: 30)
        let id = label.lowercased()
        let secret = String(rawPassword.prefix(80))
        guard !id.isEmpty else {
            suggestsSettings = false
            errorMessage = "Skriv et gruppenavn."
            return false
        }
        if !secret.isEmpty && secret.count < 4 {
            suggestsSettings = false
            errorMessage = "Passordet må ha minst 4 tegn."
            return false
        }
        guard signedIn, socketOpen else {
            suggestsSettings = false
            errorMessage = "Logg inn"
            return false
        }
        preferTalk = id
        socket.sendCreateGroup(name: label, password: secret)
        return true
    }

    @discardableResult
    func requestJoin(named rawName: String) -> Bool {
        let label = Self.clip(rawName, limit: 30)
        guard !label.isEmpty else {
            suggestsSettings = false
            errorMessage = "Skriv et gruppenavn."
            return false
        }
        guard signedIn, socketOpen else {
            suggestsSettings = false
            errorMessage = "Logg inn"
            return false
        }
        socket.sendRequestJoin(name: label)
        return true
    }

    @discardableResult
    func joinWithPassword(named rawName: String, password rawPassword: String) -> Bool {
        let label = Self.clip(rawName, limit: 30)
        let secret = String(rawPassword.prefix(80))
        guard !label.isEmpty else {
            suggestsSettings = false
            errorMessage = "Skriv et gruppenavn."
            return false
        }
        guard secret.count >= 4 else {
            suggestsSettings = false
            errorMessage = "Passordet må ha minst 4 tegn."
            return false
        }
        guard signedIn, socketOpen else {
            suggestsSettings = false
            errorMessage = "Logg inn"
            return false
        }
        socket.sendJoinWithPassword(name: label, password: secret)
        return true
    }

    @discardableResult
    func setGroupPassword(room: String, password rawPassword: String) -> Bool {
        let secret = String(rawPassword.prefix(80))
        if !secret.isEmpty && secret.count < 4 {
            suggestsSettings = false
            errorMessage = "Passordet må ha minst 4 tegn."
            return false
        }
        guard signedIn, socketOpen else {
            suggestsSettings = false
            errorMessage = "Logg inn"
            return false
        }
        socket.sendSetPassword(room: room, password: secret)
        return true
    }

    @discardableResult
    func invite(room: String, username rawUser: String) -> Bool {
        let user = Self.normalizeUsername(rawUser)
        guard Self.validUsername(user) else {
            suggestsSettings = false
            errorMessage = "Skriv et brukernavn."
            return false
        }
        socket.sendInvite(room: room, username: user)
        return true
    }

    func replyInvite(room: String, accept: Bool) {
        socket.sendInviteReply(room: room, accept: accept)
    }

    func replyRequest(room: String, username: String, accept: Bool) {
        socket.sendRequestReply(room: room, username: username, accept: accept)
    }

    func removeMember(room: String, username: String) {
        socket.sendRemoveMember(room: room, username: username)
    }

    func setListening(_ id: String, _ listen: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].listen = listen
        saveGroups()
        pushSubscribe()
    }

    func selectTalk(_ id: String) {
        guard groups.contains(where: { $0.id == id }) else { return }
        talkGroup = id
        syncRoomName()
        saveGroups()
        pushSubscribe()
    }

    func removeGroup(_ id: String) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        if group.admin {
            socket.sendDeleteGroup(room: id)
        } else {
            socket.sendLeave(room: id)
        }
        groups.removeAll { $0.id == id }
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
        pushSubscribe()
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
        guard signedIn else {
            suggestsSettings = false
            errorMessage = "Logg inn"
            return
        }
        guard linkState == .signedIn || linkState == .disconnected else { return }
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
        syncRoomName()
        serverURL = url.absoluteString
        savePreferences()
        let sameServer = socketOpen && activeURL == url
        activeURL = url
        shouldReconnect = true
        dismissError()
        linkState = .connecting
        statusText = "Kobler til…"
        connectTask?.cancel()
        if sameServer {
            connectTask = Task { await self.startAudioOnly() }
        } else {
            connectTask = Task { await self.startAudioAndSocket() }
        }
    }

    func disconnect() {
        shouldReconnect = false
        connectTask?.cancel()
        reconnectTask?.cancel()
        setVolumeButtonMonitoringEnabled(false)
        endTransmitting()
        engine.stop()
        audioReady = false
        hasConnectedOnce = false
        clearPresence()
        if signedIn && keepAccount {
            prepareVolumeHUD()
            if socketOpen {
                linkState = .signedIn
                statusText = "Innlogget"
            } else {
                openAccountSocket()
            }
            return
        }
        socket.close()
        socketOpen = false
        socketReady = false
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
        if signedIn {
            hasConnectedOnce = true
            linkState = .connected
            statusText = "Tilkoblet"
        }
        guard let activeURL else { return }
        socket.connect(url: activeURL)
    }

    private func startAudioOnly() async {
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
        hasConnectedOnce = true
        linkState = .connected
        statusText = "Tilkoblet"
        pushSubscribe()
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
        if signedIn {
            linkState = .signedIn
            statusText = "Innlogget"
        } else {
            linkState = .disconnected
            statusText = "Ikke tilkoblet"
        }
        suggestsSettings = settings
        errorMessage = message
        prepareVolumeHUD()
    }

    private func handleOpen() {
        socketOpen = true
        socketReady = false
        flushAuth()
    }

    private func handleClose() {
        socketOpen = false
        socketReady = false
        let somebodyTalking = !talkers.isEmpty
        talkers.removeAll()
        membersByRoom = [:]
        selfID = ""
        if somebodyTalking {
            engine.playTalkBoundaryBeep(isStart: false)
        }
        engine.markTalkBurstEnded()
        endTransmitting()
        let wantsAudio = shouldReconnect
        let wantsAccount = keepAccount
        guard wantsAudio || wantsAccount else { return }
        if wantsAudio {
            linkState = .reconnecting
            statusText = "Frakoblet – prøver igjen…"
        } else {
            linkState = .connecting
            restoringSession = !signedIn
            statusText = signedIn ? "Kobler til…" : "Logger inn…"
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, !self.socketOpen, let url = self.activeURL else { return }
            guard self.shouldReconnect || self.keepAccount else { return }
            self.statusText = self.signedIn ? "Kobler til…" : "Logger inn…"
            self.socket.connect(url: url)
        }
    }

    private func handle(_ event: ServerEvent) {
        switch event {
        case .session(let token, let username, let displayName):
            accountToken = token
            AccountTokenStore.save(token)
            accountUsername = username
            defaults.set(username, forKey: Key.username)
            if !displayName.isEmpty { name = displayName }
            signedIn = true
            restoringSession = false
            keepAccount = true
            socketReady = true
            pendingAuth = nil
            if audioReady {
                hasConnectedOnce = true
                linkState = .connected
                statusText = "Tilkoblet"
            } else {
                linkState = .signedIn
                statusText = "Innlogget"
            }
            savePreferences()
        case .inbox(let serverGroups, let nextInvites, let nextRequests):
            applyInbox(serverGroups, invites: nextInvites, requests: nextRequests)
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
            let text = message.isEmpty ? "Noe gikk galt" : message
            if !signedIn {
                shouldReconnect = false
                accountToken = nil
                AccountTokenStore.delete()
                keepAccount = false
                restoringSession = false
                pendingAuth = nil
                groups = []
                invites = []
                requests = []
                audioReady = false
                hasConnectedOnce = false
                engine.stop()
                clearPresence()
                socket.close()
                socketOpen = false
                socketReady = false
                linkState = .disconnected
                statusText = "Ikke tilkoblet"
                suggestsSettings = false
                errorMessage = text == "Logg inn" ? "Logg inn på nytt." : text
                prepareVolumeHUD()
                return
            }
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

    private func applyInbox(_ serverGroups: [ServerGroup], invites nextInvites: [WalkieInvite], requests nextRequests: [WalkieRequest]) {
        let previous = groups
        var next: [WalkieGroup] = []
        for item in serverGroups {
            let listen = previous.first { $0.id == item.id }?.listen ?? true
            next.append(
                WalkieGroup(
                    id: item.id,
                    name: item.name,
                    listen: listen,
                    locked: item.locked,
                    admin: item.admin,
                    roster: item.members
                )
            )
        }
        groups = next
        invites = nextInvites
        requests = nextRequests
        if let prefer = preferTalk, next.contains(where: { $0.id == prefer }) {
            talkGroup = prefer
        }
        preferTalk = nil
        if !next.contains(where: { $0.id == talkGroup }) {
            talkGroup = next.first?.id ?? ""
        }
        syncRoomName()
        saveGroups()
        if signedIn && socketReady {
            pushSubscribe()
        }
    }

    private func pushSubscribe() {
        guard socketOpen, signedIn, socketReady else { return }
        let muted = groups.filter { !$0.listen }.map(\.id)
        socket.sendSubscribe(talk: talkGroup, muted: muted)
    }

    private func flushOrOpen() {
        if socketOpen {
            flushAuth()
        } else {
            openAccountSocket()
        }
    }

    private func flushAuth() {
        guard socketOpen else { return }
        if let pending = pendingAuth {
            pendingAuth = nil
            switch pending {
            case .signup(let user, let display, let password):
                socket.sendSignup(username: user, name: display, password: password)
            case .login(let user, let password):
                socket.sendLogin(username: user, password: password)
            }
            return
        }
        if let token = accountToken, !token.isEmpty, !socketReady {
            socket.sendResume(token: token)
            return
        }
        if signedIn && socketReady {
            pushSubscribe()
        }
    }

    private func openAccountSocket() {
        guard let url = Self.normalizeServerURL(serverURL) else {
            suggestsSettings = false
            errorMessage = "Serveradressen må være ws:// eller wss://."
            restoringSession = false
            linkState = signedIn ? .signedIn : .disconnected
            return
        }
        serverURL = url.absoluteString
        activeURL = url
        savePreferences()
        keepAccount = true
        if linkState == .disconnected || linkState == .signedIn {
            linkState = .connecting
            statusText = restoringSession ? "Logger inn…" : "Kobler til…"
        }
        socket.connect(url: url)
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
        static let username = "walkie.username"
    }

    private static func normalizeUsername(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func validUsername(_ user: String) -> Bool {
        guard user.count >= 3, user.count <= 20 else { return false }
        return user.unicodeScalars.allSatisfy { scalar in
            CharacterSet.username.contains(scalar)
        }
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
    case signedIn
    case connected
    case reconnecting
}

struct AccountMember: Codable, Identifiable, Equatable {
    var username: String
    var name: String
    var role: String
    var id: String { username }

    private enum CodingKeys: String, CodingKey {
        case username, name, role
    }

    init(username: String, name: String, role: String) {
        self.username = username
        self.name = name
        self.role = role
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        role = try container.decodeIfPresent(String.self, forKey: .role) ?? "member"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(username, forKey: .username)
        try container.encode(name, forKey: .name)
        try container.encode(role, forKey: .role)
    }
}

struct ServerGroup: Decodable, Equatable {
    var id: String
    var name: String
    var admin: Bool
    var locked: Bool
    var members: [AccountMember]

    private enum CodingKeys: String, CodingKey {
        case id, name, admin, locked, members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        admin = try container.decodeIfPresent(Bool.self, forKey: .admin) ?? false
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        members = try container.decodeIfPresent([AccountMember].self, forKey: .members) ?? []
    }
}

struct WalkieInvite: Decodable, Identifiable, Equatable {
    var room: String
    var name: String
    var from: String
    var fromName: String
    var id: String { room }

    private enum CodingKeys: String, CodingKey {
        case room, name, from, fromName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        room = try container.decodeIfPresent(String.self, forKey: .room) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? room
        from = try container.decodeIfPresent(String.self, forKey: .from) ?? ""
        fromName = try container.decodeIfPresent(String.self, forKey: .fromName) ?? from
    }
}

struct WalkieRequest: Decodable, Identifiable, Equatable {
    var room: String
    var name: String
    var username: String
    var displayName: String
    var id: String { room + "/" + username }

    private enum CodingKeys: String, CodingKey {
        case room, name, username, displayName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        room = try container.decodeIfPresent(String.self, forKey: .room) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? room
        username = try container.decode(String.self, forKey: .username)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? username
    }
}

struct WalkieGroup: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var listen: Bool
    var locked: Bool
    var setsPassword: Bool
    var admin: Bool
    var roster: [AccountMember]

    private enum CodingKeys: String, CodingKey {
        case id, name, listen, locked, setsPassword, admin, roster
    }

    init(
        id: String,
        name: String,
        listen: Bool,
        locked: Bool = false,
        setsPassword: Bool = false,
        admin: Bool = false,
        roster: [AccountMember] = []
    ) {
        self.id = id
        self.name = name
        self.listen = listen
        self.locked = locked
        self.setsPassword = setsPassword
        self.admin = admin
        self.roster = roster
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        listen = try container.decodeIfPresent(Bool.self, forKey: .listen) ?? true
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        setsPassword = try container.decodeIfPresent(Bool.self, forKey: .setsPassword) ?? false
        admin = try container.decodeIfPresent(Bool.self, forKey: .admin) ?? false
        roster = try container.decodeIfPresent([AccountMember].self, forKey: .roster) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(listen, forKey: .listen)
        try container.encode(locked, forKey: .locked)
        try container.encode(setsPassword, forKey: .setsPassword)
        try container.encode(admin, forKey: .admin)
        try container.encode(roster, forKey: .roster)
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

enum AccountTokenStore {
    private static let service = "com.skuyng.walkie.account"
    private static let account = "session"

    static func save(_ token: String) {
        guard !token.isEmpty else { return }
        let data = Data(token.utf8)
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

    static func load() -> String? {
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

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension CharacterSet {
    static let username = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
}
