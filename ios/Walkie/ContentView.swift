import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var session = WalkieSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var darkMode = false
    @State private var savedBrightness: CGFloat?
    @State private var showMenu = false

    var body: some View {
        ZStack {
            AuroraBackground(live: auroraLive)
            if session.signedIn || session.restoringSession {
                talkScreen
            } else {
                LoginWindow(session: session)
            }
            if darkMode {
                darkOverlay
            }
        }
        .statusBarHidden(darkMode)
        .persistentSystemOverlays(darkMode ? .hidden : .automatic)
        .preferredColorScheme(.dark)
        .tint(Aurora.teal)
        .task {
            while !Task.isCancelled {
                session.haptics.prepare()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
        .onAppear {
            session.haptics.prepare()
            session.prepareVolumeHUD()
            refreshVolumeButtons()
        }
        .onDisappear {
            exitDarkMode()
            session.setVolumeButtonMonitoringEnabled(false)
        }
        .onChange(of: session.name) { _, _ in session.savePreferences() }
        .onChange(of: session.room) { _, _ in session.savePreferences() }
        .onChange(of: session.serverURL) { _, _ in session.savePreferences() }
        .onChange(of: session.speakerphone) { _, _ in session.saveSpeakerphone() }
        .onChange(of: session.linkState) { _, _ in refreshVolumeButtons() }
        .onChange(of: session.hasConnectedOnce) { _, connected in
            if !connected { exitDarkMode() }
        }
        .onChange(of: session.signedIn) { _, signed in
            if !signed { showMenu = false }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                session.endTransmitting()
                session.releaseIdleVolumeSession()
            } else if phase == .active {
                session.prepareVolumeHUD()
                session.resumeAudioIfNeeded()
            }
            syncDarkMode(with: phase)
            refreshVolumeButtons()
        }
        .sheet(isPresented: $showMenu) {
            HomeMenu(session: session)
                .presentationBackground {
                    AuroraBackground(live: auroraLive)
                }
        }
        .alert(session.suggestsSettings ? "Mikrofon" : "Obs", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
            if session.suggestsSettings {
                Button("Åpne Innstillinger") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var talkScreen: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 64, max(220, geo.size.height - 240))
            ZStack {
                GlassEffectContainer(spacing: 16) {
                    VStack(spacing: 16) {
                        homeTopBar
                        JoinBanner(text: session.joinProblem(for: session.talkGroup))
                        Spacer(minLength: 0)
                        talkButton(side: side)
                        HomePresence(session: session)
                        Spacer(minLength: 0)
                        TalkBottomBar(
                            speakerOn: session.speakerphone,
                            link: linkAction,
                            onSpeaker: toggleSpeaker,
                            onDark: enterDarkMode,
                            onLink: linkTapped
                        )
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .coordinateSpace(name: "talk")
            .overlayPreferenceValue(WaveAnchorKey.self) { rect in
                WaveOverlay(
                    rect: rect,
                    wave: session.levels.wave,
                    transmitting: session.isTalking,
                    receiving: !session.isTalking && !session.talkers.isEmpty
                )
            }
        }
    }

    private var homeTopBar: some View {
        ZStack {
            TuningReadout(code: talkCode, name: channelName, mode: radioMode, action: openMenu)
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 8) {
                Text("Walkie")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                profileButton
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 48)
    }

    private var profileButton: some View {
        Button(action: openMenu) {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 40, height: 40)
                .glassEffect(.regular, in: Circle())
                .overlay(alignment: .topTrailing) {
                    if hasAttention {
                        Circle()
                            .fill(Aurora.teal)
                            .frame(width: 8, height: 8)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Innstillinger")
    }

    private var hasAttention: Bool {
        !session.invites.isEmpty || !session.directRequests.isEmpty || !session.requests.isEmpty
    }

    private func openMenu() {
        showMenu = true
    }

    private func toggleSpeaker() {
        session.speakerphone.toggle()
    }

    private func linkTapped() {
        switch linkAction {
        case .connect:
            session.connect()
        case .cancel, .disconnect:
            if session.restoringSession && !session.signedIn {
                session.cancelAccountConnect()
            } else {
                session.disconnect()
            }
        }
    }

    private var linkAction: HomeLink {
        switch session.linkState {
        case .connected:
            return .disconnect
        case .connecting, .reconnecting:
            return .cancel
        case .signedIn, .disconnected:
            return .connect
        }
    }

    private func talkButton(side: CGFloat) -> some View {
        TalkButton(session: session, side: side)
    }

    private var auroraLive: Bool {
        session.isTalking || !session.talkers.isEmpty
    }

    private var talkCode: String {
        ChannelCode.label(id: session.talkGroup, groups: session.groups)
    }

    private var channelName: String {
        let match = session.groups.first { $0.id == session.talkGroup }
        let label = match?.name ?? session.room
        if label.isEmpty { return "Ingen gruppe" }
        return label
    }

    private var radioMode: String {
        if session.isTalking { return "TX" }
        if !session.talkers.isEmpty { return "RX" }
        return ""
    }

    private var darkOverlay: some View {
        ZStack {
            Color.black
            if session.isTalking {
                LedDot(on: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { exitDarkMode() }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(session.isTalking ? "Mørk modus. Snakker." : "Mørk modus")
        .accessibilityHint("Trykk for å avslutte")
        .accessibilityAction { exitDarkMode() }
    }

    private func enterDarkMode() {
        if savedBrightness == nil {
            savedBrightness = UIScreen.main.brightness
        }
        darkMode = true
        UIApplication.shared.isIdleTimerDisabled = true
        UIScreen.main.brightness = 0
    }

    private func exitDarkMode() {
        guard darkMode || savedBrightness != nil else { return }
        darkMode = false
        if let savedBrightness {
            UIScreen.main.brightness = savedBrightness
        }
        savedBrightness = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func syncDarkMode(with phase: ScenePhase) {
        guard darkMode else { return }
        UIApplication.shared.isIdleTimerDisabled = true
        if phase == .active {
            let current = UIScreen.main.brightness
            if let saved = savedBrightness, current > 0.02, abs(current - saved) > 0.02 {
                savedBrightness = current
            }
            UIScreen.main.brightness = 0
        } else if let savedBrightness {
            UIScreen.main.brightness = savedBrightness
        }
    }

    private func refreshVolumeButtons() {
        if scenePhase == .active {
            session.prepareVolumeHUD()
        }
        let listen = scenePhase == .active && session.linkState == .connected
        session.setVolumeButtonMonitoringEnabled(listen)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.dismissError() } }
        )
    }
}

private final class TalkActions {
    var begin: () -> Void = {}
    var end: () -> Void = {}
}

private struct WaveAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 {
            value = next
        }
    }
}

private struct WaveOverlay: View {
    var rect: CGRect
    var wave: WaveRing
    var transmitting: Bool
    var receiving: Bool

    var body: some View {
        if rect.width > 1 {
            ZStack {
                TalkLevelFill(wave: wave, transmitting: transmitting, receiving: receiving)
                Text("Talk")
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .frame(width: rect.width - 48, height: 30)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.7), radius: 8, y: 1)
                    .offset(y: rect.height * 0.28)
            }
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .transaction { $0.disablesAnimations = true }
        }
    }
}

private struct TalkButton: View {
    @ObservedObject var session: WalkieSession
    var side: CGFloat
    @State private var actions = TalkActions()

    var body: some View {
        TalkPressTarget(side: side, enabled: session.canTransmit, actions: actions)
            .equatable()
            .overlay(TalkButtonFace(side: side).allowsHitTesting(false))
            .opacity(session.canTransmit ? 1 : 0.45)
            .background(waveAnchor)
            .onAppear(perform: bindActions)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Talk")
            .accessibilityHint("Hold inne for å snakke. Med VoiceOver aktiverer du for å starte og stoppe. Hold volum opp inne for å snakke.")
            .accessibilityAction {
                if session.isTalking {
                    session.endTransmitting()
                } else {
                    session.beginTransmitting()
                }
            }
    }

    private var waveAnchor: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: WaveAnchorKey.self, value: proxy.frame(in: .named("talk")))
        }
    }

    private func bindActions() {
        actions.begin = { session.beginTransmitting() }
        actions.end = { session.endTransmitting() }
    }
}

/// Fixed hit target. Equality ignores talk state so a press does not rebuild the gesture.
private struct TalkPressTarget: View, Equatable {
    var side: CGFloat
    var enabled: Bool
    var actions: TalkActions

    static func == (lhs: TalkPressTarget, rhs: TalkPressTarget) -> Bool {
        lhs.side == rhs.side && lhs.enabled == rhs.enabled
    }

    var body: some View {
        Color.clear
            .frame(width: side, height: side)
            .contentShape(Circle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in actions.begin() }
                    .onEnded { _ in actions.end() }
            )
            .allowsHitTesting(enabled)
    }
}

private struct TalkButtonFace: View {
    var side: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .background(.ultraThinMaterial, in: Circle())
                .glassEffect(.regular.tint(Color.white.opacity(0.12)), in: Circle())
            Image(systemName: "mic.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.white.opacity(0.2))
        }
        .frame(width: side, height: side)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
    }
}

private struct JoinBanner: View {
    let text: String

    var body: some View {
        if text.isEmpty {
            EmptyView()
        } else {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(.red), in: Capsule())
        }
    }
}

private enum HomeLink: Equatable {
    case connect, cancel, disconnect
}

private struct HomePresence: View {
    @ObservedObject var session: WalkieSession

    var body: some View {
        VStack(spacing: 8) {
            speakerLine
            faceRow
        }
        .frame(height: 64)
    }

    private var speakerLine: some View {
        ZStack {
            Text(" ")
            if !session.speakerLine.isEmpty {
                Label(session.speakerLine, systemImage: "speaker.wave.2.fill")
                    .labelStyle(.titleAndIcon)
                    .symbolEffect(.variableColor.iterative)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .font(.system(.subheadline, design: .monospaced).weight(.medium))
        .foregroundStyle(Aurora.teal)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .accessibilityHidden(session.speakerLine.isEmpty)
    }

    private var faceRow: some View {
        HStack(spacing: 8) {
            if session.linkState == .connected && !members.isEmpty {
                HStack(spacing: -8) {
                    ForEach(shownMembers) { member in
                        PresenceFace(member: member)
                    }
                }
                Text(countText)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(session.centerStatus)
            } else {
                Text(idleText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
    }

    private var members: [OnlineMember] {
        session.onlineMembers(in: session.talkGroup)
    }

    private var shownMembers: [OnlineMember] {
        Array(members.prefix(4))
    }

    private var countText: String {
        "\(members.count)"
    }

    private var idleText: String {
        if session.linkState == .connected { return "Ingen pålogget" }
        return session.statusText
    }
}

private struct PresenceFace: View {
    let member: OnlineMember

    var body: some View {
        Text(initial)
            .font(.caption.weight(.semibold))
            .foregroundStyle(member.talking ? Aurora.teal : .primary)
            .frame(width: 32, height: 32)
            .background(.ultraThinMaterial, in: Circle())
            .glassEffect(.regular, in: Circle())
            .overlay {
                if member.talking {
                    Circle().strokeBorder(Aurora.teal, lineWidth: 1.5)
                }
            }
            .accessibilityLabel(member.talking ? "\(member.name) snakker" : member.name)
    }

    private var initial: String {
        let trimmed = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

private struct TalkBottomBar: View {
    var speakerOn: Bool
    var link: HomeLink
    var onSpeaker: () -> Void
    var onDark: () -> Void
    var onLink: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TalkIconButton(
                systemImage: speakerIcon,
                title: speakerTitle,
                tint: speakerTint,
                action: onSpeaker
            )
            TalkIconButton(systemImage: "moon.fill", title: "Mørk modus", tint: .primary, action: onDark)
            if link == .connect {
                Button(action: onLink) {
                    Text("Koble til")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Aurora.teal)
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Koble til")
            } else {
                TalkIconButton(systemImage: linkIcon, title: linkTitle, tint: linkTint, action: onLink)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private var speakerIcon: String {
        speakerOn ? "speaker.wave.3.fill" : "speaker.slash.fill"
    }

    private var speakerTint: Color {
        speakerOn ? .primary : .secondary
    }

    private var speakerTitle: String {
        speakerOn ? "Høyttaler på" : "Høyttaler av"
    }

    private var linkIcon: String {
        switch link {
        case .connect:
            return "antenna.radiowaves.left.and.right"
        case .cancel:
            return "xmark"
        case .disconnect:
            return "phone.down.fill"
        }
    }

    private var linkTitle: String {
        switch link {
        case .connect:
            return "Koble til"
        case .cancel:
            return "Avbryt"
        case .disconnect:
            return "Koble fra"
        }
    }

    private var linkTint: Color {
        switch link {
        case .connect:
            return Aurora.teal
        case .cancel:
            return .primary
        case .disconnect:
            return .red
        }
    }
}

private struct TalkIconButton: View {
    var systemImage: String
    var title: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct HomeMenu: View {
    @ObservedObject var session: WalkieSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                GlassEffectContainer(spacing: 16) {
                    VStack(alignment: .leading, spacing: 24) {
                        SettingsBlock("Grupper") {
                            GroupEditor(session: session)
                        }
                        SettingsBlock("Kontakter") {
                            DirectSection(session: session)
                        }
                        SettingsBlock("Konto") {
                            VStack(alignment: .leading, spacing: 16) {
                                accountHeader
                                AccountFooter(session: session, onLogOut: logOut)
                            }
                        }
                        SettingsBlock("Om") {
                            VStack(alignment: .leading, spacing: 16) {
                                LegalLinks(server: session.serverURL)
                                serverField
                            }
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 8)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Innstillinger")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ferdig") { dismiss() }
                }
            }
        }
    }

    private var accountHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(displayName)
                .font(.title2.weight(.semibold))
                .lineLimit(1)
            if !session.accountUsername.isEmpty {
                Text("@\(session.accountUsername)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayName: String {
        if session.name.isEmpty { return session.accountUsername }
        return session.name
    }

    private var serverField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Server")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(WalkieSession.defaultServerURL, text: $session.serverURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .submitLabel(.done)
                .auroraField()
        }
    }

    private func logOut() {
        session.logOut()
        dismiss()
    }
}

private struct SettingsBlock<Content: View>: View {
    var title: String
    var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

private struct LoginWindow: View {
    @ObservedObject var session: WalkieSession
    @State private var username = ""
    @State private var password = ""
    @State private var showSignUp = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case username, password
    }

    var body: some View {
        if showSignUp {
            SignUpWindow(session: session, onClose: { showSignUp = false })
        } else {
            loginForm
        }
    }

    private var loginForm: some View {
        ScrollView {
            GlassEffectContainer(spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    logo
                    labeledField("Brukernavn") {
                        TextField("brukernavn", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .submitLabel(.next)
                            .focused($focus, equals: .username)
                            .onSubmit { focus = .password }
                            .glassFieldChrome()
                    }
                    labeledField("Passord") {
                        SecureField("Minst 4 tegn", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit(logIn)
                            .glassFieldChrome()
                    }
                    Button(action: logIn) {
                        Text("Logg inn")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Aurora.teal)
                    .controlSize(.large)
                    .disabled(busy)
                    Button("Opprett bruker", action: { showSignUp = true })
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    Button("Personvern", action: openPrivacy)
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    if busy {
                        Text("Logger inn…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        Button("Avbryt") { session.cancelAccountConnect() }
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if username.isEmpty { username = session.accountUsername }
        }
    }

    private var logo: some View {
        VStack(spacing: 16) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 34, weight: .semibold))
                .frame(width: 88, height: 88)
                .glassEffect(.regular.tint(Aurora.teal), in: Circle())
            Text("Walkie")
                .font(.largeTitle.weight(.bold))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
    }

    private var busy: Bool {
        session.linkState == .connecting || session.linkState == .reconnecting
    }

    private func logIn() {
        session.logIn(username: username, password: password)
    }

    private func openPrivacy() {
        guard let url = WalkieSession.webPage("/personvern", server: session.serverURL) else { return }
        UIApplication.shared.open(url)
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct SignUpWindow: View {
    @ObservedObject var session: WalkieSession
    var onClose: () -> Void
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var acceptedTerms = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case username, displayName, password
    }

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    Button(action: onClose) {
                        Label("Tilbake", systemImage: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    Text("Opprett bruker")
                        .font(.title2.weight(.semibold))
                    labeledField("Brukernavn") {
                        TextField("brukernavn", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .submitLabel(.next)
                            .focused($focus, equals: .username)
                            .onSubmit { focus = .displayName }
                            .glassFieldChrome()
                    }
                    labeledField("Visningsnavn") {
                        TextField("Navnet andre ser", text: $displayName)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.next)
                            .focused($focus, equals: .displayName)
                            .onSubmit { focus = .password }
                            .glassFieldChrome()
                    }
                    labeledField("Passord") {
                        SecureField("Minst 4 tegn", text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.newPassword)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit(signUp)
                            .glassFieldChrome()
                    }
                    Toggle("Jeg godtar vilkårene", isOn: $acceptedTerms)
                        .tint(Aurora.teal)
                    LegalLinks(server: session.serverURL)
                    Button(action: signUp) {
                        Text("Opprett bruker")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Aurora.teal)
                    .controlSize(.large)
                    .disabled(busy || !acceptedTerms)
                    if busy {
                        Text("Oppretter konto…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        Button("Avbryt") { session.cancelAccountConnect() }
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(24)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if username.isEmpty { username = session.accountUsername }
            if displayName.isEmpty { displayName = session.name }
        }
    }

    private var busy: Bool {
        session.linkState == .connecting || session.linkState == .reconnecting
    }

    private func signUp() {
        session.signUp(username: username, displayName: displayName, password: password, acceptedTerms: acceptedTerms)
    }

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct GroupEditor: View {
    @ObservedObject var session: WalkieSession
    @State private var draftName = ""
    @State private var draftPassword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !session.invites.isEmpty {
                InviteSection(session: session)
            }
            groupFields
        }
    }

    private var groupFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Gruppenavn (f.eks. Familie)", text: $draftName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .glassFieldChrome()
            SecureField("Passord (valgfritt)", text: $draftPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .glassFieldChrome()
            HStack(spacing: 8) {
                CapsuleChoice(title: "Opprett gruppe", prominent: true, height: 48, expands: true, action: createTapped)
                CapsuleChoice(title: joinTitle, prominent: false, height: 48, expands: true, action: joinTapped)
            }
            .frame(maxWidth: .infinity)
            GroupList(session: session)
        }
    }

    private var joinTitle: String {
        draftPassword.isEmpty ? "Be om å bli med" : "Bli med"
    }

    private func createTapped() {
        let saved = session.createGroup(named: draftName, password: draftPassword)
        if saved {
            draftName = ""
            draftPassword = ""
        }
    }

    private func joinTapped() {
        let saved = draftPassword.isEmpty
            ? session.requestJoin(named: draftName)
            : session.joinWithPassword(named: draftName, password: draftPassword)
        if saved {
            draftName = ""
            draftPassword = ""
        }
    }
}

private struct InviteSection: View {
    @ObservedObject var session: WalkieSession

    var body: some View {
        if session.invites.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Invitasjoner")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(session.invites) { invite in
                    InviteRow(session: session, invite: invite)
                }
            }
        }
    }
}

private struct InviteRow: View {
    @ObservedObject var session: WalkieSession
    let invite: WalkieInvite

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(invite.name)
                .font(.headline)
            Text(fromLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Godta") { session.replyInvite(room: invite.room, accept: true) }
                .buttonStyle(.glassProminent)
                .tint(Aurora.teal)
            Button("Avslå") { session.replyInvite(room: invite.room, accept: false) }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraCard()
    }

    private var fromLine: String {
        if invite.fromName.isEmpty { return "Invitasjon" }
        return "Fra \(invite.fromName)"
    }
}

private struct FieldHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CapsuleChoice: View {
    var title: String
    var prominent: Bool
    var height: CGFloat
    var expands: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, expands ? 8 : 16)
                .frame(maxWidth: expands ? .infinity : nil)
                .frame(height: height)
                .background { Capsule().fill(fill) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(prominent ? Color.black : Color.primary)
    }

    private var fill: Color {
        prominent ? Aurora.teal : Color.white.opacity(0.14)
    }
}

private struct DirectSection: View {
    @ObservedObject var session: WalkieSession
    @State private var username = ""
    @State private var fieldHeight: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                TextField("Brukernavn", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(send)
                    .glassFieldChrome()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: FieldHeightKey.self, value: proxy.size.height)
                        }
                    }
                CapsuleChoice(
                    title: "Søk bruker",
                    prominent: false,
                    height: fieldHeight,
                    expands: false,
                    action: send
                )
            }
            .onPreferenceChange(FieldHeightKey.self) { height in
                if height > 0 { fieldHeight = height }
            }
            ForEach(session.directRequests) { request in
                DirectRequestRow(session: session, request: request)
            }
            ForEach(session.groups.filter(\.direct)) { group in
                GroupRow(session: session, group: group)
            }
        }
    }

    private func send() {
        let saved = session.requestDirect(username: username)
        if saved { username = "" }
    }
}

private struct DirectRequestRow: View {
    @ObservedObject var session: WalkieSession
    let request: DirectRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if request.incoming {
                    Button("Godta") { session.replyDirect(username: request.username, accept: true) }
                        .buttonStyle(.glassProminent)
                        .tint(Aurora.teal)
                    Button("Avslå") { session.replyDirect(username: request.username, accept: false) }
                        .buttonStyle(.glass)
                } else {
                    Button("Avbryt") { session.replyDirect(username: request.username, accept: false) }
                        .buttonStyle(.glass)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraCard()
    }

    private var person: String {
        if request.name.isEmpty { return "@\(request.username)" }
        return "\(request.name) (@\(request.username))"
    }

    private var headline: String {
        request.incoming ? person : "Venter på \(person)"
    }

    private var detail: String {
        request.incoming ? "Vil snakke direkte" : "Forespørselen er sendt"
    }
}

private struct GroupList: View {
    @ObservedObject var session: WalkieSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(session.groups.filter { !$0.direct }) { group in
                GroupRow(session: session, group: group)
            }
        }
    }
}

private struct GroupRow: View {
    @ObservedObject var session: WalkieSession
    let group: WalkieGroup
    @State private var confirmDirect = false
    @State private var confirmReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if group.direct {
                    LedDot(on: session.peerIsOnline(in: group.id))
                        .accessibilityLabel(onlineLabel)
                }
                ChannelTitle(
                    code: ChannelCode.label(id: group.id, groups: session.groups),
                    name: group.name
                )
                if group.locked {
                    Image(systemName: "lock.fill")
                        .font(.caption.weight(.semibold))
                        .accessibilityLabel("Passord")
                }
                if group.admin {
                    Text("admin")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button(talkTitle, action: select)
                    .buttonStyle(.glass)
                Button(role: .destructive, action: removeTapped) {
                    Image(systemName: "trash")
                        .font(.body.weight(.semibold))
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Fjern \(group.name)")
            }
            Toggle("Lytt", isOn: listenBinding)
            if group.direct && !group.peer.isEmpty {
                HStack(spacing: 8) {
                    Button(blockTitle) { session.setBlocked(group.peer, !session.isBlocked(group.peer)) }
                        .buttonStyle(.glass)
                    Button("Rapporter") { confirmReport = true }
                        .buttonStyle(.glass)
                }
            }
            if group.admin && !group.direct {
                AdminTools(session: session, group: group)
            }
            if !group.direct {
                RosterList(session: session, group: group)
            }
            ProblemLine(text: session.joinProblem(for: group.id))
            MemberList(session: session, groupID: group.id)
            PresenceCaption(text: session.presenceCaption(for: group.id))
        }
        .auroraCard()
        .confirmationDialog(directTitle, isPresented: $confirmDirect, titleVisibility: .visible) {
            Button("Avslutt", role: .destructive, action: remove)
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Kanalen slettes for begge.")
        }
        .alert(reportTitle, isPresented: $confirmReport) {
            Button("Send", action: reportPeer)
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Rapporten lagres hos serveren. Misbruk tåles ikke.")
        }
    }

    private var blockTitle: String {
        session.isBlocked(group.peer) ? "Opphev blokkering" : "Blokker"
    }

    private var reportTitle: String {
        "Rapportere \(group.name)?"
    }

    private func reportPeer() {
        session.report(username: group.peer, room: group.id)
    }

    private var onlineLabel: String {
        session.peerIsOnline(in: group.id) ? "Pålogget" : "Ikke pålogget"
    }

    private var directTitle: String {
        "Avslutte direkte med \(group.name)?"
    }

    private var talkTitle: String {
        session.talkGroup == group.id ? "Talk" : "Velg"
    }

    private var listenBinding: Binding<Bool> {
        Binding(
            get: { group.listen },
            set: { session.setListening(group.id, $0) }
        )
    }

    private func select() {
        session.selectTalk(group.id)
    }

    private func removeTapped() {
        if group.direct {
            confirmDirect = true
        } else {
            remove()
        }
    }

    private func remove() {
        session.removeGroup(group.id)
    }
}

private struct AdminTools: View {
    @ObservedObject var session: WalkieSession
    let group: WalkieGroup
    @State private var inviteName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PasswordEditor(session: session, groupID: group.id, locked: group.locked)
            HStack(spacing: 8) {
                TextField("Brukernavn", text: $inviteName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(invite)
                    .glassFieldChrome()
                Button("Invitér", action: invite)
                    .buttonStyle(.glass)
            }
            ForEach(pendingRequests) { request in
                RequestRow(session: session, request: request)
            }
        }
    }

    private var pendingRequests: [WalkieRequest] {
        session.requests.filter { $0.room == group.id }
    }

    private func invite() {
        let saved = session.invite(room: group.id, username: inviteName)
        if saved { inviteName = "" }
    }
}

private struct PasswordEditor: View {
    @ObservedObject var session: WalkieSession
    let groupID: String
    let locked: Bool
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(placeholder, text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .submitLabel(.done)
                .onSubmit(save)
                .glassFieldChrome()
            HStack(spacing: 8) {
                Button("Lagre passord", action: save)
                    .buttonStyle(.glass)
                if locked {
                    Button("Fjern passord", action: clear)
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private var placeholder: String {
        locked ? "Nytt passord" : "Passord (valgfritt)"
    }

    private func save() {
        guard !password.isEmpty else { return }
        let saved = session.setGroupPassword(room: groupID, password: password)
        if saved { password = "" }
    }

    private func clear() {
        let saved = session.setGroupPassword(room: groupID, password: "")
        if saved { password = "" }
    }
}

private struct RequestRow: View {
    @ObservedObject var session: WalkieSession
    let request: WalkieRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(requestLabel)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                Button("Godta") { session.replyRequest(room: request.room, username: request.username, accept: true) }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                Button("Avslå") { session.replyRequest(room: request.room, username: request.username, accept: false) }
                    .buttonStyle(.glass)
            }
        }
    }

    private var requestLabel: String {
        "\(request.displayName) (@\(request.username)) ber om å bli med"
    }
}

private struct RosterList: View {
    @ObservedObject var session: WalkieSession
    let group: WalkieGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(group.roster) { member in
                RosterLine(session: session, groupID: group.id, member: member, admin: group.admin)
            }
        }
    }
}

private struct RosterLine: View {
    @ObservedObject var session: WalkieSession
    let groupID: String
    let member: AccountMember
    let admin: Bool
    @State private var confirmRemove = false
    @State private var confirmReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(memberLine)
                .font(.subheadline)
            HStack(spacing: 8) {
                if canModerate {
                    Button(blockTitle) { session.setBlocked(member.username, !session.isBlocked(member.username)) }
                        .buttonStyle(.glass)
                    Button("Rapporter") { confirmReport = true }
                        .buttonStyle(.glass)
                }
                if canRemove {
                    Button("Fjern") { confirmRemove = true }
                        .buttonStyle(.glass)
                }
            }
        }
        .alert(reportTitle, isPresented: $confirmReport) {
            Button("Send", action: report)
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Rapporten lagres hos serveren. Misbruk tåles ikke.")
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Fjern", role: .destructive, action: remove)
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Medlemmet mister tilgang til gruppen.")
        }
    }

    private var reportTitle: String {
        "Rapportere \(memberLine)?"
    }

    private var blockTitle: String {
        session.isBlocked(member.username) ? "Opphev blokkering" : "Blokker"
    }

    private var confirmTitle: String {
        "Fjerne \(memberLine)?"
    }

    private var memberLine: String {
        if member.name.isEmpty { return "@\(member.username)" }
        return "\(member.name) (@\(member.username))"
    }

    private var canRemove: Bool {
        admin && member.username != session.accountUsername && member.role != "admin"
    }

    private var canModerate: Bool {
        member.username != session.accountUsername
    }

    private func remove() {
        session.removeMember(room: groupID, username: member.username)
    }

    private func report() {
        session.report(username: member.username, room: groupID)
    }
}

private struct LegalLinks: View {
    let server: String

    var body: some View {
        HStack(spacing: 16) {
            Button("Personvern") { open("/personvern") }
            Button("Vilkår") { open("/vilkar") }
        }
        .buttonStyle(.plain)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func open(_ path: String) {
        guard let url = WalkieSession.webPage(path, server: server) else { return }
        UIApplication.shared.open(url)
    }
}

private struct AccountFooter: View {
    @ObservedObject var session: WalkieSession
    var onLogOut: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button("Logg ut", action: onLogOut)
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
            Button("Slett konto") { confirmDelete = true }
                .buttonStyle(.glass)
                .tint(.red)
                .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Slette kontoen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Slett konto", role: .destructive) { session.deleteAccount() }
            Button("Avbryt", role: .cancel) {}
        } message: {
            Text("Brukeren, øktene og medlemskapene slettes. Grupper du eier alene slettes. Ellers får det eldste medlemmet admin. Dette kan ikke angres.")
        }
    }
}

private struct MemberList: View {
    @ObservedObject var session: WalkieSession
    let groupID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.onlineMembers(in: groupID)) { member in
                MemberLine(member: member)
            }
        }
    }
}

private struct ProblemLine: View {
    let text: String

    var body: some View {
        if text.isEmpty {
            EmptyView()
        } else {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct PresenceCaption: View {
    let text: String

    var body: some View {
        if text.isEmpty {
            EmptyView()
        } else {
            Text(text)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MemberLine: View {
    let member: OnlineMember

    var body: some View {
        HStack(spacing: 8) {
            LedDot(on: true)
            Text(label)
                .font(nameFont)
                .foregroundStyle(nameColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var label: String {
        member.talking ? "\(member.name) snakker" : member.name
    }

    private var nameFont: Font {
        member.talking ? .body.weight(.semibold) : .body
    }

    private var nameColor: Color {
        member.talking ? Aurora.violet : .primary
    }
}

private extension View {
    func glassFieldChrome() -> some View {
        auroraField()
    }
}

#Preview {
    ContentView()
}
