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
    @Published private(set) var statusCode: LinkCopy = .disconnected
    @Published private(set) var membersByRoom: [String: [RoomMember]] = [:]
    @Published private(set) var selfID = ""
    @Published private(set) var joinProblems: [String: String] = [:]
    @Published private(set) var talkers: [Talker] = []
    @Published private(set) var isTalking = false
    @Published private(set) var audioReady = false
    @Published private(set) var errorNotice: AppNotice?
    @Published private(set) var suggestsSettings = false
    @Published private(set) var hasConnectedOnce = false
    @Published private(set) var listenOutput: ListenOutput
    @Published private(set) var listenGain: Double
    @Published private(set) var userMatches: [UserMatch] = []
    @Published private(set) var contactNote = ""
    @Published private(set) var signedIn = false
    @Published private(set) var restoringSession = false
    @Published private(set) var accountUsername = ""
    @Published private(set) var invites: [WalkieInvite] = []
    @Published private(set) var requests: [WalkieRequest] = []
    @Published private(set) var blockedUsernames: [String] = []
    @Published private(set) var directRequests: [DirectRequest] = []
    @Published var quietHoursEnabled = false
    @Published var quietFromMinutes = 22 * 60
    @Published var quietToMinutes = 7 * 60
    @Published private(set) var heardClips: [String: HeardClip] = [:]
    @Published private(set) var language: AppLanguage = .nb
    @Published private(set) var captionsEnabled: Bool
    @Published private(set) var captionText = ""
    @Published private(set) var captionSpeaker = ""
    @Published private(set) var captionVisible = false

    var statusText: String {
        L10n.text(statusCode.key, language)
    }

    var errorMessage: String? {
        errorNotice.map { L10n.notice($0, language) }
    }

    func t(_ key: LKey) -> String {
        L10n.text(key, language)
    }

    func tf(_ key: LKey, _ values: String...) -> String {
        L10n.format(key, language, values)
    }

    func setLanguage(_ next: AppLanguage) {
        language = next
        defaults.set(next.rawValue, forKey: Key.language)
        captions.setLocale(Self.speechLocale(next))
    }

    func setCaptionsEnabled(_ on: Bool) {
        captionsEnabled = on
        defaults.set(on, forKey: Key.captions)
        captions.setEnabled(on)
        if on {
            captions.requestAuthorizationIfNeeded()
        } else {
            captionFade?.cancel()
            captionVisible = false
            captionText = ""
            captionSpeaker = ""
        }
    }

    var canTransmit: Bool {
        linkState == .connected && audioReady
    }

    /// Someone is talking on the channel this phone is joined to.
    var hearingThisChannel: Bool {
        talkers.contains { $0.room == talkGroup }
    }

    var speakerLine: String {
        var namesByRoom: [String: [String]] = [:]
        var order: [String] = []
        for talker in talkers where talker.room == talkGroup {
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
            return tf(.speakingIn, names.joined(separator: ", "), label)
        }
        if parts.isEmpty { return "" }
        return parts.joined(separator: " · ") + " " + t(.speakingTail)
    }

    var centerStatus: String {
        if linkState != .connected { return statusText }
        let count = onlineMembers(in: talkGroup).count
        if count == 0 { return t(.nobodyOnline) }
        if count == 1 { return t(.oneOnline) }
        return tf(.manyOnline, "\(count)")
    }

    func joinProblem(for groupID: String) -> String {
        guard let raw = joinProblems[groupID], !raw.isEmpty else { return "" }
        return L10n.phrase(raw, language)
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
        if onlineMembers(in: groupID).isEmpty { return t(.nobodyOnline) }
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
    let haptics = WalkieHaptics()
    let levels = AudioLevels()
    private let engine = VoiceEngine()
    private let captions = CaptionEngine()
    private let socket = WalkieSocket()
    private let transmitter = HoldToTalkTransmitter()
    private let volumeButtons = VolumeButtonMonitor()
    private let headsetTalk = HeadsetTalkControl()
    private var activeURL: URL?
    private var shouldReconnect = false
    /// Koble fra holds for this process only. The next launch connects again.
    private var suppressAutoConnect = false
    private var connectTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var accountToken: String?
    private var pendingAuth: PendingAuth?
    private var keepAccount = false
    private var socketOpen = false
    private var socketReady = false
    /// Bumps when talk ends so a late ready chirp does not open the mic.
    private var readyGeneration = 0
    /// Talk-stop waits until the release tail has actually been sent.
    private var pendingStop = false
    private var userSearchQuery = ""
    private var pendingAdd = ""
    private var preferTalk: String?
    private var reconnectAttempt = 0
    private var quietTimer: Timer?
    private var openHeard: [String: OpenHeard] = [:]
    private var heardAudio: [String: Data] = [:]
    private var pendingHeard = Data()
    private var captionFade: Task<Void, Never>?

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
        listenOutput = Self.storedListenOutput(defaults)
        let storedGain = defaults.object(forKey: Key.listenGain) as? Double ?? 1
        listenGain = min(1, max(0, storedGain))
        language = AppLanguage.resolved(stored: defaults.string(forKey: Key.language))
        quietHoursEnabled = defaults.bool(forKey: Key.quietEnabled)
        quietFromMinutes = Self.clampMinutes(defaults.object(forKey: Key.quietFrom) as? Int ?? (22 * 60))
        quietToMinutes = Self.clampMinutes(defaults.object(forKey: Key.quietTo) as? Int ?? (7 * 60))
        if defaults.object(forKey: Key.captions) == nil {
            captionsEnabled = true
        } else {
            captionsEnabled = defaults.bool(forKey: Key.captions)
        }
        engine.setListenGain(Float(listenGain))
        engine.setInboundChannel(talkGroup)
        engine.setSpeakerphone(listenOutput != .earpiece)
        engine.setIncomingMuted(Self.quietHoursCover(enabled: quietHoursEnabled, from: quietFromMinutes, to: quietToMinutes, at: Date()) || listenOutput == .mute)
        engine.attachLevelMeter(levels.wave)
        engine.activateForSystemVolume()
        captions.setEnabled(captionsEnabled)
        captions.setLocale(Self.speechLocale(language))
        captions.onTranscript = { [weak self] line in
            self?.applyCaption(line)
        }
        if captionsEnabled {
            captions.requestAuthorizationIfNeeded()
        }

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
            guard let self else { return }
            guard self.engine.acceptsInboundAudio() else { return }
            self.engine.playIncoming(data)
            let captured = data
            Task { @MainActor [weak self] in
                self?.rememberIncoming(captured)
                self?.captions.append(captured)
            }
        }
        engine.setCaptureHandler { [weak self] data in
            self?.socket.send(audio: data)
        }
        engine.onFailure = { [weak self] alert in
            Task { @MainActor in
                guard let self else { return }
                self.audioReady = false
                let denied = AVAudioApplication.shared.recordPermission != .granted
                self.errorNotice = .audio(denied ? .microphoneDenied : alert)
                self.suggestsSettings = denied
            }
        }
        engine.onInterrupted = { [weak self] in
            Task { @MainActor in self?.endTransmitting() }
        }
        // Category changes post volume events on this turn. The ignore window
        // has to be armed before setCategory returns, or a full-volume Talk
        // press looks like volume-up and releases itself a moment later.
        engine.onSessionReconfigured = { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.volumeButtons.noteSessionReconfigured()
                self.haptics.prepare()
            }
        }
        engine.onSendIdle = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingStop else { return }
                self.pendingStop = false
                self.socket.sendStop(room: self.talkGroup)
            }
        }
        if let token = AccountTokenStore.load(), !token.isEmpty {
            accountToken = token
            keepAccount = true
            restoringSession = true
            statusCode = .signingIn
            linkState = .connecting
            openAccountSocket()
        }
        haptics.prepare()
        startQuietClock()
    }

    func setQuietHoursEnabled(_ enabled: Bool) {
        quietHoursEnabled = enabled
        persistQuietHours()
    }

    func setQuietFrom(_ date: Date) {
        quietFromMinutes = Self.clampMinutes(Self.minutes(from: date))
        persistQuietHours()
    }

    func setQuietTo(_ date: Date) {
        quietToMinutes = Self.clampMinutes(Self.minutes(from: date))
        persistQuietHours()
    }

    var quietHoursLabel: String {
        "\(Self.clock(quietFromMinutes))–\(Self.clock(quietToMinutes))"
    }

    func heardClip(in room: String) -> HeardClip? {
        heardClips[room]
    }

    func replayLast(in room: String) {
        guard let data = heardAudio[room], !data.isEmpty else { return }
        engine.playClip(data)
    }

    func savePreferences() {
        defaults.set(name, forKey: Key.name)
        defaults.set(room, forKey: Key.room)
        defaults.set(serverURL, forKey: Key.server)
        saveGroups()
    }

    func signUp(username rawUser: String, displayName rawDisplay: String, password rawPassword: String, acceptedTerms: Bool) {
        guard acceptedTerms else {
            suggestsSettings = false
            errorNotice = .key(.acceptTerms)
            return
        }
        let user = Self.normalizeUsername(rawUser)
        let display = Self.clip(rawDisplay, limit: 30)
        let password = String(rawPassword.prefix(80))
        guard Self.validUsername(user) else {
            suggestsSettings = false
            errorNotice = .key(.usernameRule)
            return
        }
        guard !display.isEmpty else {
            suggestsSettings = false
            errorNotice = .key(.enterName)
            return
        }
        guard password.count >= 4 else {
            suggestsSettings = false
            errorNotice = .key(.passwordRule)
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
            errorNotice = .key(.usernameRule)
            return
        }
        guard password.count >= 4 else {
            suggestsSettings = false
            errorNotice = .key(.passwordRule)
            return
        }
        pendingAuth = .login(user: user, password: password)
        dismissError()
        flushOrOpen()
    }

    func logOut() {
        keepAccount = false
        shouldReconnect = false
        suppressAutoConnect = false
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
        blockedUsernames = []
        directRequests = []
        userMatches = []
        contactNote = ""
        userSearchQuery = ""
        pendingAdd = ""
        talkGroup = ""
        room = ""
        preferTalk = nil
        engine.setInboundChannel("")
        clearHeard()
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
        statusCode = .disconnected
    }

    @discardableResult
    func createGroup(named rawName: String, password rawPassword: String) -> Bool {
        let label = Self.clip(rawName, limit: 30)
        let id = label.lowercased()
        let secret = String(rawPassword.prefix(80))
        guard !id.isEmpty else {
            suggestsSettings = false
            errorNotice = .key(.enterGroupName)
            return false
        }
        if !secret.isEmpty && secret.count < 4 {
            suggestsSettings = false
            errorNotice = .key(.passwordRule)
            return false
        }
        guard signedIn, socketOpen else {
            suggestsSettings = false
            errorNotice = .key(.signIn)
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
            errorNotice = .key(.enterGroupName)
            return false
        }
        guard signedIn, socketOpen else {
            suggestsSettings = false
            errorNotice = .key(.signIn)
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
            errorNotice = .key(.enterGroupName)
            return false
        }
        guard secret.count >= 4 else {
            suggestsSettings = false
            errorNotice = .key(.passwordRule)
            return false
        }
        guard signedIn, socketOpen else {
            suggestsSettings = false
            errorNotice = .key(.signIn)
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
            errorNotice = .key(.passwordRule)
            return false
        }
        guard signedIn, socketOpen else {
            suggestsSettings = false
            errorNotice = .key(.signIn)
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
            errorNotice = .key(.enterUsername)
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

    func isBlocked(_ username: String) -> Bool {
        blockedUsernames.contains(username)
    }

    func setBlocked(_ username: String, _ blocked: Bool) {
        if blocked {
            socket.sendBlock(username: username)
        } else {
            socket.sendUnblock(username: username)
        }
    }

    func report(username: String, room: String) {
        socket.sendReport(username: username, room: room, reason: "Uakseptabel oppførsel")
    }

    func deleteAccount() {
        guard signedIn, socketOpen else {
            suggestsSettings = false
            errorNotice = .key(.signIn)
            return
        }
        socket.sendDeleteAccount()
    }

    static func webPage(_ path: String, server: String) -> URL? {
        guard let socketURL = normalizeServerURL(server),
              var parts = URLComponents(url: socketURL, resolvingAgainstBaseURL: false) else { return nil }
        if parts.scheme == "wss" { parts.scheme = "https" }
        if parts.scheme == "ws" { parts.scheme = "http" }
        parts.path = path
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    func setListening(_ id: String, _ listen: Bool) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].listen = listen
        saveGroups()
        pushSubscribe()
    }

    func selectTalk(_ id: String) {
        guard groups.contains(where: { $0.id == id }) else { return }
        let switched = talkGroup != id
        talkGroup = id
        if switched { parkInboundChannel() }
        syncRoomName()
        saveGroups()
        pushSubscribe()
        connectIfNeeded(overridingManual: true)
    }

    func searchUsers(raw: String) {
        let query = Self.contactQuery(raw)
        userSearchQuery = query
        pendingAdd = ""
        userMatches = []
        guard !query.isEmpty else {
            contactNote = "Skriv et brukernavn."
            return
        }
        guard signedIn, socketOpen else {
            contactNote = "Logg inn"
            return
        }
        contactNote = ""
        socket.sendSearchUsers(username: query)
    }

    func addContact(username rawUser: String) {
        let user = Self.normalizeUsername(Self.contactQuery(rawUser))
        guard Self.validUsername(user) else {
            contactNote = "Skriv et brukernavn."
            return
        }
        guard user != accountUsername else {
            contactNote = "Du kan ikke kontakte deg selv."
            return
        }
        guard signedIn, socketOpen else {
            contactNote = "Logg inn"
            return
        }
        pendingAdd = user
        if let index = userMatches.firstIndex(where: { $0.username == user }) {
            userMatches[index].state = "sent"
        }
        contactNote = ""
        socket.sendDirect(username: user)
    }

    func replyDirect(username: String, accept: Bool) {
        socket.sendDirectReply(username: username, accept: accept)
    }

    func peerIsOnline(in groupID: String) -> Bool {
        let people = membersByRoom[groupID] ?? []
        if selfID.isEmpty {
            return people.contains { $0.name != name }
        }
        return people.contains { $0.id != selfID }
    }

    func removeGroup(_ id: String) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        if group.direct {
            socket.sendRemoveDirect(room: id)
        } else if group.admin {
            socket.sendDeleteGroup(room: id)
        } else {
            socket.sendLeave(room: id)
        }
        groups.removeAll { $0.id == id }
        membersByRoom[id] = nil
        joinProblems[id] = nil
        openHeard[id] = nil
        heardAudio[id] = nil
        heardClips[id] = nil
        let leaving = talkers.filter { $0.room == id }
        for talker in leaving {
            removeTalker(id: talker.id, room: talker.room)
        }
        if talkGroup == id {
            if isTalking { endTransmitting() }
            talkGroup = groups.first?.id ?? ""
            parkInboundChannel()
            syncRoomName()
        }
        saveGroups()
        pushSubscribe()
    }

    /// Leave a group you belong to. Admin hands the role to the oldest other member.
    /// An empty group is deleted. The live channel disconnects and the next one connects.
    func leaveGroup(_ id: String) {
        guard let group = groups.first(where: { $0.id == id }), !group.direct else { return }
        guard signedIn, socketOpen else {
            suggestsSettings = false
            errorNotice = .key(.signIn)
            return
        }
        socket.sendLeave(room: id)
        let wasCurrent = talkGroup == id
        groups.removeAll { $0.id == id }
        membersByRoom[id] = nil
        joinProblems[id] = nil
        openHeard[id] = nil
        heardAudio[id] = nil
        heardClips[id] = nil
        let leaving = talkers.filter { $0.room == id }
        for talker in leaving {
            removeTalker(id: talker.id, room: talker.room)
        }
        if wasCurrent {
            if isTalking { endTransmitting() }
            talkGroup = groups.first?.id ?? ""
            parkInboundChannel()
            syncRoomName()
            saveGroups()
            disconnect()
            if !talkGroup.isEmpty {
                connect()
            }
        } else {
            saveGroups()
            pushSubscribe()
        }
    }

    var listenModeTitle: String {
        switch listenOutput {
        case .speaker: return t(.listenSpeaker)
        case .earpiece: return t(.listenEarpiece)
        case .mute: return t(.listenMuted)
        }
    }

    var listenSymbol: String {
        switch listenOutput {
        case .speaker: return "speaker.wave.3.fill"
        case .earpiece: return "ear.fill"
        case .mute: return "speaker.slash.fill"
        }
    }

    func cycleListenOutput() {
        let next: ListenOutput
        switch listenOutput {
        case .speaker: next = .earpiece
        case .earpiece: next = .mute
        case .mute: next = .speaker
        }
        setListenOutput(next)
    }

    func setListenOutput(_ output: ListenOutput) {
        listenOutput = output
        defaults.set(output.rawValue, forKey: Key.listenOutput)
        defaults.set(output != .earpiece, forKey: Key.speakerphone)
        applyListenRoute()
    }

    private func applyListenRoute() {
        engine.setIncomingMuted(isQuietHours() || listenOutput == .mute)
        switch listenOutput {
        case .speaker:
            engine.setSpeakerphone(true)
        case .earpiece:
            engine.setSpeakerphone(false)
        case .mute:
            break
        }
    }

    func setListenGain(_ value: Double) {
        let clamped = min(1, max(0, value))
        listenGain = clamped
        defaults.set(clamped, forKey: Key.listenGain)
        engine.setListenGain(Float(clamped))
    }

    /// Foreground keeps the capture graph warm. Background idle cools it.
    func setCaptureWarm(_ active: Bool) {
        engine.setCaptureWarm(active)
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
        errorNotice = nil
        suggestsSettings = false
    }

    /// Joins the last channel when a logged-in app opens or returns to the foreground.
    /// A manual hang-up skips this until the next launch, or until the user picks a channel.
    func connectIfNeeded(overridingManual: Bool = false) {
        if overridingManual {
            suppressAutoConnect = false
        }
        guard !suppressAutoConnect else { return }
        guard signedIn else { return }
        guard linkState == .signedIn || linkState == .disconnected else { return }
        guard !groups.isEmpty else { return }
        if AVAudioApplication.shared.recordPermission == .denied { return }
        connect()
    }

    func connect() {
        guard signedIn else {
            suggestsSettings = false
            errorNotice = .key(.signIn)
            return
        }
        guard linkState == .signedIn || linkState == .disconnected else { return }
        guard !groups.isEmpty else {
            suggestsSettings = false
            errorNotice = .key(.needGroup)
            return
        }
        suppressAutoConnect = false
        resolveTalkChannel()
        guard let url = Self.normalizeServerURL(serverURL) else {
            suggestsSettings = false
            errorNotice = .key(.badServer)
            return
        }
        syncRoomName()
        serverURL = url.absoluteString
        savePreferences()
        let sameServer = socketOpen && activeURL == url
        activeURL = url
        shouldReconnect = true
        reconnectAttempt = 0
        dismissError()
        linkState = .connecting
        statusCode = .connecting
        connectTask?.cancel()
        if sameServer {
            connectTask = Task { await self.startAudioOnly() }
        } else {
            connectTask = Task { await self.startAudioAndSocket() }
        }
    }

    /// Hang up from the bottom bar. The next launch still connects on its own.
    func disconnectManually() {
        suppressAutoConnect = true
        disconnect()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectAttempt = 0
        connectTask?.cancel()
        reconnectTask?.cancel()
        setVolumeButtonMonitoringEnabled(false)
        endTransmitting()
        if pendingStop {
            pendingStop = false
            socket.sendStop(room: talkGroup)
        }
        engine.stop()
        audioReady = false
        hasConnectedOnce = false
        clearPresence()
        if signedIn && keepAccount {
            prepareVolumeHUD()
            if socketOpen {
                linkState = .signedIn
                statusCode = .signedIn
            } else {
                openAccountSocket()
            }
            return
        }
        socket.close()
        socketOpen = false
        socketReady = false
        linkState = .disconnected
        statusCode = .disconnected
        prepareVolumeHUD()
    }

    func beginTransmitting() {
        let was = transmitter.isTransmitting
        transmitter.beginTransmitting()
        if !was && transmitter.isTransmitting {
            haptics.pressTalk()
            engine.stopPlaybackClip()
        }
    }

    /// Play/pause on a headset toggles talk. Volume-up is unchanged.
    func setHeadsetTalkEnabled(_ enabled: Bool) {
        headsetTalk.setEnabled(enabled) { [weak self] in
            guard let self else { return }
            if self.transmitter.isTransmitting {
                self.endTransmitting()
            } else {
                self.beginTransmitting()
            }
        }
    }

    /// Stops the hold. The mic gate stays open for a short tail, and the
    /// foreground engine stays warm.
    func endTransmitting() {
        let was = transmitter.isTransmitting
        transmitter.endTransmitting()
        if was && !transmitter.isTransmitting {
            haptics.releaseTalk()
        }
    }

    /// Volume-up holds transmitting only while the caller reports that the
    /// app is in the foreground and the channel is connected.
    func setVolumeButtonMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            haptics.prepare()
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
            failBeforeSession(.microphoneDenied, settings: true)
            return
        }
        do {
            try engine.start()
        } catch let error as VoiceEngineError {
            failBeforeSession(Self.audioAlert(error), settings: error == .microphoneDenied || AVAudioApplication.shared.recordPermission != .granted)
            return
        } catch {
            failBeforeSession(.failedToStart, settings: false)
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
            statusCode = .connected
        }
        guard let activeURL else { return }
        socket.connect(url: activeURL)
    }

    private func startAudioOnly() async {
        let granted = await requestMicrophoneAccess()
        guard shouldReconnect, !Task.isCancelled else { return }
        guard granted else {
            failBeforeSession(.microphoneDenied, settings: true)
            return
        }
        do {
            try engine.start()
        } catch let error as VoiceEngineError {
            failBeforeSession(Self.audioAlert(error), settings: error == .microphoneDenied || AVAudioApplication.shared.recordPermission != .granted)
            return
        } catch {
            failBeforeSession(.failedToStart, settings: false)
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
        statusCode = .connected
        pushSubscribe()
    }

    /// Always asks before the engine starts. A granted or denied answer returns
    /// immediately; the system sheet is shown only when the choice is still open.
    private func requestMicrophoneAccess() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func failBeforeSession(_ alert: AudioAlert, settings: Bool) {
        shouldReconnect = false
        reconnectAttempt = 0
        audioReady = false
        engine.stop()
        clearPresence()
        if signedIn {
            linkState = .signedIn
            statusCode = .signedIn
        } else {
            linkState = .disconnected
            statusCode = .disconnected
        }
        suggestsSettings = settings
        errorNotice = .audio(alert)
        prepareVolumeHUD()
    }

    private static func audioAlert(_ error: VoiceEngineError) -> AudioAlert {
        switch error {
        case .noInput:
            return .noInput
        case .failedToStart:
            return .failedToStart
        case .microphoneDenied:
            return .microphoneDenied
        }
    }

    private func handleOpen() {
        socketOpen = true
        socketReady = false
        flushAuth()
    }

    private func handleClose() {
        socketOpen = false
        socketReady = false
        finishAllHeardClips()
        let somebodyTalking = !talkers.isEmpty
        talkers.removeAll()
        engine.resetInboundTalk()
        membersByRoom = [:]
        selfID = ""
        if somebodyTalking, !isQuietHours() {
            engine.playTalkBoundaryBeep(isStart: false)
        }
        engine.markTalkBurstEnded()
        endTransmitting()
        let wantsAudio = shouldReconnect
        let wantsAccount = keepAccount
        guard wantsAudio || wantsAccount else { return }
        if wantsAudio {
            linkState = .reconnecting
            statusCode = .reconnecting
        } else {
            linkState = .connecting
            restoringSession = !signedIn
            statusCode = signedIn ? .connecting : .signingIn
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let attempt = reconnectAttempt
        reconnectAttempt = min(attempt + 1, 8)
        let delay = Self.reconnectDelay(attempt)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.socketOpen, let url = self.activeURL else { return }
            guard self.shouldReconnect || self.keepAccount else { return }
            self.statusCode = self.signedIn ? .connecting : .signingIn
            self.socket.connect(url: url)
        }
    }

    private static func reconnectDelay(_ attempt: Int) -> TimeInterval {
        let steps: [TimeInterval] = [1, 2, 4, 8, 16, 30]
        return steps[min(max(0, attempt), steps.count - 1)]
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
            reconnectAttempt = 0
            pendingAuth = nil
            if audioReady {
                hasConnectedOnce = true
                linkState = .connected
                statusCode = .connected
            } else {
                linkState = .signedIn
                statusCode = .signedIn
            }
            savePreferences()
            connectIfNeeded()
        case .inbox(let serverGroups, let nextInvites, let nextRequests, let blocked, let directs):
            blockedUsernames = blocked
            directRequests = directs
            applyInbox(serverGroups, invites: nextInvites, requests: nextRequests)
            noteContactRequests()
        case .userSearch(let query, let matches, let error):
            guard query == userSearchQuery else { return }
            userMatches = matches
            contactNote = matches.isEmpty ? (error.isEmpty ? "Fant ikke brukeren" : error) : ""
        case .reported:
            suggestsSettings = false
            errorNotice = .key(.reportSent)
        case .accountDeleted:
            suggestsSettings = false
            errorNotice = .key(.accountDeleted)
            logOut()
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
            let channel = room.isEmpty ? talkGroup : room
            guard channel == talkGroup else {
                engine.noteInboundTalk(room: channel, started: true)
                pendingHeard.removeAll(keepingCapacity: true)
                return
            }
            engine.noteInboundTalk(room: channel, started: true)
            addTalker(id: id, name: name, room: channel)
        case .talkStopped(let name, let room, let id):
            let channel = room.isEmpty ? talkGroup : room
            guard channel == talkGroup else {
                engine.noteInboundTalk(room: channel, started: false)
                return
            }
            engine.noteInboundTalk(room: channel, started: false)
            removeTalker(id: id.isEmpty ? name : id, room: channel)
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
                directRequests = []
                userMatches = []
                contactNote = ""
                audioReady = false
                hasConnectedOnce = false
                engine.stop()
                clearPresence()
                socket.close()
                socketOpen = false
                socketReady = false
                linkState = .disconnected
                statusCode = .disconnected
                suggestsSettings = false
                errorNotice = text == "Logg inn" ? .key(.loginAgain) : .phrase(text)
                prepareVolumeHUD()
                return
            }
            if text == "Du er fjernet fra gruppen" || text == "Direktekanalen er avsluttet" {
                endTransmitting()
            }
            if room.isEmpty && Self.isContactPhrase(text) {
                contactNote = text
                applyContactError(text)
                return
            }
            if !room.isEmpty {
                joinProblems[room] = text
            }
            let label = groups.first { $0.id == room }?.name ?? room
            if label.isEmpty {
                errorNotice = .phrase(text)
            } else {
                errorNotice = .room(label, text)
            }
        }
    }

    private func isLocalTalker(id: String, name talkerName: String) -> Bool {
        if id == "local" { return true }
        if !selfID.isEmpty && id == selfID { return true }
        if selfID.isEmpty && isTalking && !talkerName.isEmpty && talkerName == name { return true }
        return false
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
        if captionsEnabled && !captionText.isEmpty {
            captions.endUtterance()
            scheduleCaptionFade()
        }
    }

    private func startQuietClock() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.applyQuietHours()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
    }

    private func applyQuietHours() {
        engine.setIncomingMuted(isQuietHours() || listenOutput == .mute)
    }

    private func noteContactRequests() {
        for index in userMatches.indices {
            let username = userMatches[index].username
            if let request = directRequests.first(where: { $0.username == username }) {
                userMatches[index].state = request.incoming ? "incoming" : "sent"
            } else if groups.contains(where: { $0.direct && $0.peer == username }) {
                userMatches[index].state = "contact"
            }
        }
        guard !pendingAdd.isEmpty else { return }
        if directRequests.contains(where: { $0.username == pendingAdd && $0.incoming == false }) {
            contactNote = "Forespørselen er sendt."
            pendingAdd = ""
        }
    }

    private func applyContactError(_ text: String) {
        guard !pendingAdd.isEmpty, let index = userMatches.firstIndex(where: { $0.username == pendingAdd }) else {
            pendingAdd = ""
            return
        }
        if text.contains("allerede direkte") {
            userMatches[index].state = "contact"
        } else if text.contains("Forespørselen er sendt") {
            userMatches[index].state = "sent"
        } else if text.contains("forespørsel") {
            userMatches[index].state = "incoming"
        } else if text.contains("denne brukeren") {
            userMatches[index].state = "blocked"
        } else if text.contains("deg selv") {
            userMatches[index].state = "self"
        } else {
            userMatches[index].state = "add"
        }
        pendingAdd = ""
    }

    private func isQuietHours(at date: Date = Date()) -> Bool {
        Self.quietHoursCover(enabled: quietHoursEnabled, from: quietFromMinutes, to: quietToMinutes, at: date)
    }

    private func persistQuietHours() {
        defaults.set(quietHoursEnabled, forKey: Key.quietEnabled)
        defaults.set(quietFromMinutes, forKey: Key.quietFrom)
        defaults.set(quietToMinutes, forKey: Key.quietTo)
        applyQuietHours()
    }

    static func quietHoursCover(enabled: Bool, from: Int, to: Int, at date: Date) -> Bool {
        guard enabled else { return false }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if from == to { return false }
        if from < to { return now >= from && now < to }
        return now >= from || now < to
    }

    static func clock(_ minutes: Int) -> String {
        let clamped = min(1439, max(0, minutes))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    static func minutes(from date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return clampMinutes((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
    }

    static func clampMinutes(_ minutes: Int) -> Int {
        min(1439, max(0, minutes))
    }

    static func date(fromMinutes minutes: Int) -> Date {
        let clamped = min(1439, max(0, minutes))
        var parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        parts.hour = clamped / 60
        parts.minute = clamped % 60
        parts.second = 0
        return Calendar.current.date(from: parts) ?? Date()
    }

    private func rememberIncoming(_ data: Data) {
        guard !data.isEmpty else { return }
        var rooms: [String: [String]] = [:]
        for talker in talkers {
            if isLocalTalker(id: talker.id, name: talker.name) { continue }
            guard !talker.room.isEmpty else { continue }
            rooms[talker.room, default: []].append(talker.name)
        }
        if rooms.isEmpty {
            Self.appendHeard(&pendingHeard, data, limit: Self.leadHeardBytes)
            return
        }
        let lead = pendingHeard
        if !lead.isEmpty {
            pendingHeard.removeAll(keepingCapacity: true)
        }
        for (room, names) in rooms {
            var open = openHeard[room] ?? OpenHeard()
            if open.data.isEmpty, !lead.isEmpty {
                Self.appendHeard(&open.data, lead, limit: Self.maxHeardBytes)
            }
            for name in names where !name.isEmpty && !open.names.contains(name) {
                open.names.append(name)
            }
            Self.appendHeard(&open.data, data, limit: Self.maxHeardBytes)
            openHeard[room] = open
        }
    }

    private func remoteStillTalking(in room: String) -> Bool {
        talkers.contains { $0.room == room && !isLocalTalker(id: $0.id, name: $0.name) }
    }

    private func finishHeardClip(_ room: String) {
        guard let open = openHeard.removeValue(forKey: room) else { return }
        guard open.data.count >= 3_200, !open.names.isEmpty else { return }
        heardAudio[room] = open.data
        heardClips[room] = HeardClip(sender: open.names.joined(separator: ", "), at: Date())
    }

    private func finishAllHeardClips() {
        for room in Array(openHeard.keys) {
            finishHeardClip(room)
        }
    }

    private func clearHeard() {
        openHeard.removeAll()
        pendingHeard.removeAll()
        heardAudio.removeAll()
        heardClips = [:]
    }

    private static let maxHeardBytes = 45 * 32_000
    private static let leadHeardBytes = 16_000

    private static func appendHeard(_ buffer: inout Data, _ more: Data, limit: Int) {
        buffer.append(more)
        if buffer.count <= limit { return }
        var drop = buffer.count - limit
        if drop % 2 != 0 { drop += 1 }
        if drop >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
            return
        }
        buffer.removeFirst(drop)
    }

    private func addTalker(id: String, name: String, room: String) {
        guard !room.isEmpty, !name.isEmpty else { return }
        let key = id.isEmpty ? name : id
        guard !talkers.contains(where: { $0.id == key && $0.room == room }) else { return }
        talkers.append(Talker(id: key, name: name, room: room))
        let local = isLocalTalker(id: key, name: name)
        if local || !isQuietHours() {
            engine.playTalkBoundaryBeep(isStart: true)
        }
        if !local {
            haptics.remoteStarted()
            if room == talkGroup {
                captionSpeaker = remoteCaptionSpeaker
                captionFade?.cancel()
                if !captionText.isEmpty {
                    captionVisible = true
                }
            }
        }
    }

    private func removeTalker(id: String, room: String) {
        guard let index = talkers.firstIndex(where: { $0.id == id && $0.room == room }) else { return }
        let local = isLocalTalker(id: id, name: "")
        talkers.remove(at: index)
        if local {
            engine.playTalkBoundaryBeep(isStart: false)
        } else if !isQuietHours() {
            engine.playRogerTone()
        }
        if !local {
            haptics.remoteStopped()
            if room == talkGroup {
                captionSpeaker = remoteCaptionSpeaker
                if !remoteStillTalking(in: talkGroup) {
                    captions.endUtterance()
                    scheduleCaptionFade()
                }
            }
        }
        if !remoteStillTalking(in: room) {
            finishHeardClip(room)
        }
        if talkers.isEmpty {
            engine.markTalkBurstEnded()
        }
    }

    private func applyInbox(_ serverGroups: [ServerGroup], invites nextInvites: [WalkieInvite], requests nextRequests: [WalkieRequest]) {
        let previous = groups
        let previousTalk = talkGroup
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
                    roster: item.members,
                    direct: item.direct,
                    peer: item.peer
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
            if isTalking {
                endTransmitting()
            }
            talkGroup = next.first?.id ?? ""
        }
        syncRoomName()
        if talkGroup != previousTalk {
            parkInboundChannel()
        }
        saveGroups()
        if signedIn && socketReady {
            pushSubscribe()
        }
        connectIfNeeded()
    }

    /// Drop speaker pulse, haptics, and replay for every channel except the one
    /// this phone just joined. Does not rebuild the audio graph.
    private func parkInboundChannel() {
        engine.setInboundChannel(talkGroup)
        let keep = talkGroup
        talkers.removeAll { $0.room != keep }
        openHeard = openHeard.filter { $0.key == keep }
        pendingHeard.removeAll(keepingCapacity: true)
        if talkers.isEmpty {
            engine.markTalkBurstEnded()
        }
    }

    /// Last saved channel, or the first group or direct chat still on the account.
    private func resolveTalkChannel() {
        if groups.contains(where: { $0.id == talkGroup }) { return }
        talkGroup = groups.first?.id ?? ""
        parkInboundChannel()
        syncRoomName()
        if !talkGroup.isEmpty {
            saveGroups()
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
            errorNotice = .key(.badServer)
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
            statusCode = restoringSession ? .signingIn : .connecting
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
        static let listenOutput = "walkie.listenOutput"
        static let listenGain = "walkie.listenGain"
        static let groups = "walkie.groups"
        static let talkGroup = "walkie.talkGroup"
        static let username = "walkie.username"
        static let quietEnabled = "walkie.quiet.enabled"
        static let quietFrom = "walkie.quiet.from"
        static let quietTo = "walkie.quiet.to"
        static let language = "walkie.language"
        static let captions = "walkie.captions"
    }

    private static func speechLocale(_ language: AppLanguage) -> String {
        language == .en ? "en-US" : "nb-NO"
    }

    private var remoteCaptionSpeaker: String {
        talkers
            .filter { $0.room == talkGroup && !isLocalTalker(id: $0.id, name: $0.name) }
            .map(\.name)
            .joined(separator: ", ")
    }

    private func applyCaption(_ line: String) {
        guard captionsEnabled else { return }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        captionText = trimmed
        if captionSpeaker.isEmpty {
            captionSpeaker = remoteCaptionSpeaker
        }
        captionFade?.cancel()
        captionVisible = true
    }

    private func scheduleCaptionFade() {
        captionFade?.cancel()
        captionFade = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            captionVisible = false
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, !captionVisible else { return }
            captionText = ""
            captionSpeaker = ""
        }
    }

    private static func storedListenOutput(_ defaults: UserDefaults) -> ListenOutput {
        if let raw = defaults.string(forKey: Key.listenOutput), let mode = ListenOutput(rawValue: raw) {
            return mode
        }
        if let speaker = defaults.object(forKey: Key.speakerphone) as? Bool {
            return speaker ? .speaker : .earpiece
        }
        return .speaker
    }

    private static func isContactPhrase(_ text: String) -> Bool {
        text == "Skriv et brukernavn."
            || text == "Fant ikke brukeren"
            || text == "Du kan ikke kontakte deg selv."
            || text == "Du kan ikke kontakte denne brukeren."
            || text == "Dere snakker allerede direkte."
            || text == "Forespørselen er sendt."
            || text == "Forespørselen er sendt"
            || text == "Du har en forespørsel. Godta den."
            || text == "Logg inn"
    }

    /// Trim, drop a leading @, and collapse whitespace. Case stays for display-name search.
    static func contactQuery(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{200C}", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix("@") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let parts = text.split { $0.isWhitespace }
        text = parts.joined(separator: " ")
        if text.count > 40 {
            text = String(text.prefix(40))
        }
        return text
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
        pendingStop = false
        socket.sendStart(room: talkGroup)
    }

    func sendTalkStop() {
        pendingStop = true
    }

    func setMicrophoneOpen(_ open: Bool) {
        if !open {
            readyGeneration += 1
            engine.setMicrophoneOpen(false)
            return
        }
        readyGeneration += 1
        let generation = readyGeneration
        let ready = engine.beginSending()
        guard ready, isTalking, readyGeneration == generation else {
            if ready { engine.setMicrophoneOpen(false) }
            return
        }
        guard audioReady, socketReady, socketOpen else { return }
        engine.playReadyChirp { }
    }
}

enum ListenOutput: String {
    case speaker
    case earpiece
    case mute
}

struct UserMatch: Identifiable, Equatable, Decodable {
    var username: String
    var name: String
    var state: String
    var id: String { username }

    private enum CodingKeys: String, CodingKey {
        case username, name, state
    }

    init(username: String, name: String, state: String) {
        self.username = username
        self.name = name
        self.state = state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "add"
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
    var direct: Bool
    var peer: String
    var members: [AccountMember]

    private enum CodingKeys: String, CodingKey {
        case id, name, admin, locked, direct, peer, members
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? id
        admin = try container.decodeIfPresent(Bool.self, forKey: .admin) ?? false
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
        direct = try container.decodeIfPresent(Bool.self, forKey: .direct) ?? false
        peer = try container.decodeIfPresent(String.self, forKey: .peer) ?? ""
        members = try container.decodeIfPresent([AccountMember].self, forKey: .members) ?? []
    }
}

struct DirectRequest: Decodable, Identifiable, Equatable {
    var username: String
    var name: String
    var incoming: Bool
    var id: String { username + (incoming ? "/in" : "/out") }

    private enum CodingKeys: String, CodingKey {
        case username, name, incoming
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        username = try container.decode(String.self, forKey: .username)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        incoming = try container.decodeIfPresent(Bool.self, forKey: .incoming) ?? false
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
    var direct: Bool
    var peer: String

    private enum CodingKeys: String, CodingKey {
        case id, name, listen, locked, setsPassword, admin, roster, direct, peer
    }

    init(
        id: String,
        name: String,
        listen: Bool,
        locked: Bool = false,
        setsPassword: Bool = false,
        admin: Bool = false,
        roster: [AccountMember] = [],
        direct: Bool = false,
        peer: String = ""
    ) {
        self.id = id
        self.name = name
        self.listen = listen
        self.locked = locked
        self.setsPassword = setsPassword
        self.admin = admin
        self.roster = roster
        self.direct = direct
        self.peer = peer
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
        direct = try container.decodeIfPresent(Bool.self, forKey: .direct) ?? false
        peer = try container.decodeIfPresent(String.self, forKey: .peer) ?? ""
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
        try container.encode(direct, forKey: .direct)
        try container.encode(peer, forKey: .peer)
    }
}

struct RoomMember: Codable, Equatable, Identifiable {
    var id: String
    var name: String
}

struct HeardClip: Equatable {
    var sender: String
    var at: Date
}

private struct OpenHeard {
    var names: [String] = []
    var data = Data()
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
