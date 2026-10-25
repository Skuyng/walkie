import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var session = WalkieSession()
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focus: Field?
    @State private var darkMode = false
    @State private var savedBrightness: CGFloat?
    @State private var showGroups = false

    private enum Field: Hashable {
        case server
    }

    var body: some View {
        ZStack {
            AuroraBackground(live: auroraLive)
            if !session.signedIn {
                AccountGate(session: session)
            } else if session.hasConnectedOnce {
                talkScreen
            } else {
                homeScreen
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
        .sheet(isPresented: $showGroups) {
            GroupSheet(session: session)
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

    private var homeScreen: some View {
        ScrollView {
            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 34, weight: .semibold))
                            .frame(width: 88, height: 88)
                            .glassEffect(.regular.tint(Aurora.teal), in: Circle())
                        Text("Walkie")
                            .font(.largeTitle.weight(.bold))
                        Text(accountCaption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)

                    GroupEditor(session: session)

                    labeledField("Server") {
                        TextField(WalkieSession.defaultServerURL, text: $session.serverURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .submitLabel(.go)
                            .focused($focus, equals: .server)
                            .onSubmit { session.connect() }
                            .auroraField()
                    }

                    Button(action: session.connect) {
                        Label(
                            session.linkState == .connecting ? "Kobler til…" : "Koble til",
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Aurora.teal)
                    .controlSize(.large)
                    .disabled(session.linkState == .connecting || session.linkState == .reconnecting)
                    .padding(.top, 4)

                    if session.linkState == .connecting || session.linkState == .reconnecting {
                        Label(session.statusText, systemImage: statusSymbol)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        Button("Avbryt", systemImage: "xmark") { session.disconnect() }
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity)
                    }

                    Button("Logg ut", action: session.logOut)
                        .buttonStyle(.glass)
                        .frame(maxWidth: .infinity)
                    AccountFooter(session: session)
                }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var accountCaption: String {
        if session.accountUsername.isEmpty { return session.name }
        if session.name.isEmpty { return "@\(session.accountUsername)" }
        return "\(session.name) (@\(session.accountUsername))"
    }

    private var talkScreen: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 64, max(220, geo.size.height - 240))
            GlassEffectContainer(spacing: 16) {
                VStack(spacing: 18) {
                    TuningReadout(code: talkCode, name: channelName, mode: radioMode, action: openGroups)
                    JoinBanner(text: session.joinProblem(for: session.talkGroup))
                    Spacer(minLength: 0)
                    speakerRow
                    talkButton(side: side)
                    CenterStatusLine(text: session.centerStatus, symbol: statusSymbol)
                    Spacer(minLength: 0)
                    TalkBottomBar(
                        speakerOn: session.speakerphone,
                        onSpeaker: toggleSpeaker,
                        onDark: enterDarkMode,
                        onGroups: openGroups,
                        onDisconnect: disconnectTapped
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func openGroups() {
        showGroups = true
    }

    private func toggleSpeaker() {
        session.speakerphone.toggle()
    }

    private func disconnectTapped() {
        session.disconnect()
    }

    private var speakerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2.fill")
                .symbolEffect(.variableColor.iterative, isActive: !session.speakerLine.isEmpty)
            Text(session.speakerLine.isEmpty ? " " : session.speakerLine)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
        }
        .font(.system(.title3, design: .monospaced).weight(.semibold))
        .foregroundStyle(Aurora.teal)
        .frame(maxWidth: .infinity)
        .frame(height: 32)
        .opacity(session.speakerLine.isEmpty ? 0 : 1)
        .accessibilityHidden(session.speakerLine.isEmpty)
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

    private var statusSymbol: String {
        switch session.linkState {
        case .connected:
            return "checkmark.circle.fill"
        case .signedIn:
            return "person.crop.circle"
        case .connecting:
            return "ellipsis.circle.fill"
        case .reconnecting:
            return "arrow.triangle.2.circlepath"
        case .disconnected:
            return "circle.slash"
        }
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

    private func labeledField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
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

private struct TalkButton: View {
    @ObservedObject var session: WalkieSession
    var side: CGFloat
    @State private var actions = TalkActions()

    var body: some View {
        TalkPressTarget(side: side, enabled: session.canTransmit, actions: actions)
            .equatable()
            .overlay(
                TalkButtonFace(
                    side: side,
                    levels: session.levels,
                    transmitting: session.isTalking,
                    receiving: !session.isTalking && !session.talkers.isEmpty
                )
                .allowsHitTesting(false)
            )
            .opacity(session.canTransmit ? 1 : 0.45)
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
    var levels: AudioLevels
    var transmitting: Bool
    var receiving: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .background(.ultraThinMaterial, in: Circle())
                .glassEffect(.regular.tint(Color.white.opacity(0.12)), in: Circle())
            Image(systemName: "mic.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.white.opacity(0.2))
            TalkLevelFill(levels: levels, transmitting: transmitting, receiving: receiving)
                .clipShape(Circle())
            Text("Talk")
                .font(.title2.weight(.semibold))
                .lineLimit(1)
                .frame(width: side - 48, height: 30)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 8, y: 1)
                .offset(y: side * 0.28)
        }
        .frame(width: side, height: side)
        .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
    }
}

private struct TalkGroupPill: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.left.and.right")
                Text(title)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .font(.headline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Åpner gruppene")
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
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(.red), in: Capsule())
        }
    }
}

private struct CenterStatusLine: View {
    var text: String
    var symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(.subheadline, design: .monospaced).weight(.medium))
            .foregroundStyle(.secondary)
            .symbolRenderingMode(.hierarchical)
    }
}

private struct TalkBottomBar: View {
    var speakerOn: Bool
    var onSpeaker: () -> Void
    var onDark: () -> Void
    var onGroups: () -> Void
    var onDisconnect: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TalkIconButton(
                systemImage: speakerIcon,
                title: speakerTitle,
                tint: speakerTint,
                action: onSpeaker
            )
            TalkIconButton(systemImage: "moon.fill", title: "Mørk modus", tint: .primary, action: onDark)
            TalkIconButton(systemImage: "person.3.fill", title: "Grupper", tint: .primary, action: onGroups)
            TalkIconButton(systemImage: "phone.down.fill", title: "Koble fra", tint: .red, action: onDisconnect)
        }
        .padding(.horizontal, 12)
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
}

private struct TalkIconButton: View {
    var systemImage: String
    var title: String
    var tint: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 52, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

private struct GroupSheet: View {
    @ObservedObject var session: WalkieSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                GroupEditor(session: session)
                    .padding(20)
                AccountFooter(session: session)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Grupper")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Logg ut") {
                        session.logOut()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ferdig") { dismiss() }
                }
            }
        }
    }
}

private struct AccountGate: View {
    @ObservedObject var session: WalkieSession
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var acceptedTerms = false
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case username, displayName, password, server
    }

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 12) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(spacing: 12) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 34, weight: .semibold))
                            .frame(width: 88, height: 88)
                            .glassEffect(.regular.tint(Aurora.teal), in: Circle())
                        Text("Walkie")
                            .font(.largeTitle.weight(.bold))
                        Text("Logg inn, eller opprett en konto.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)

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
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit { logIn() }
                            .glassFieldChrome()
                    }
                    labeledField("Server") {
                        TextField(WalkieSession.defaultServerURL, text: $session.serverURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .submitLabel(.go)
                            .focused($focus, equals: .server)
                            .onSubmit { logIn() }
                            .glassFieldChrome()
                    }
                    Toggle("Jeg godtar vilkårene", isOn: $acceptedTerms)
                        .tint(Aurora.teal)
                    LegalLinks(server: session.serverURL)
                    Button(action: signUp) {
                        Text("Opprett konto")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Aurora.teal)
                    .controlSize(.large)
                    .disabled(busy || !acceptedTerms)
                    Button(action: logIn) {
                        Text("Logg inn")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .disabled(busy)
                    if busy {
                        Label(session.restoringSession ? "Logger inn…" : session.statusText, systemImage: "ellipsis.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        Button("Avbryt") { session.cancelAccountConnect() }
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if username.isEmpty { username = session.accountUsername }
            if displayName.isEmpty { displayName = session.name }
        }
    }

    private var busy: Bool {
        session.restoringSession || session.linkState == .connecting || session.linkState == .reconnecting
    }

    private func signUp() {
        session.signUp(username: username, displayName: displayName, password: password, acceptedTerms: acceptedTerms)
    }

    private func logIn() {
        session.logIn(username: username, password: password)
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
        VStack(alignment: .leading, spacing: 12) {
            DirectSection(session: session)
            InviteSection(session: session)
            Text("Gruppe")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
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
            HStack(spacing: 10) {
                Button(action: createTapped) {
                    Text("Opprett gruppe")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(Aurora.teal)
                Button(action: joinTapped) {
                    Text(joinTitle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
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
                .font(.system(.headline, design: .monospaced))
            Text(fromLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
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

private struct DirectSection: View {
    @ObservedObject var session: WalkieSession
    @State private var username = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Direkte")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Brukernavn", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(send)
                    .glassFieldChrome()
                Button("Be om kontakt", action: send)
                    .buttonStyle(.glass)
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
            HStack(spacing: 10) {
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
        VStack(alignment: .leading, spacing: 6) {
            Text(requestLabel)
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
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
        .foregroundStyle(.red)
    }

    private func open(_ path: String) {
        guard let url = WalkieSession.webPage(path, server: server) else { return }
        UIApplication.shared.open(url)
    }
}

private struct AccountFooter: View {
    @ObservedObject var session: WalkieSession
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Konto")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            LegalLinks(server: session.serverURL)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var label: String {
        member.talking ? "\(member.name) snakker" : member.name
    }

    private var nameFont: Font {
        if member.talking { return .system(.body, design: .monospaced).weight(.bold) }
        return .system(.body, design: .monospaced)
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
