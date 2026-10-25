import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var session = WalkieSession()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focus: Field?
    @State private var darkMode = false
    @State private var savedBrightness: CGFloat?
    @State private var showGroups = false

    private enum Field: Hashable {
        case server
    }

    var body: some View {
        ZStack {
            WalkieBackdrop(transmitting: session.isTalking)
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
        .onAppear {
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
                            .glassEffect(.regular.tint(.red), in: Circle())
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
                            .glassFieldChrome()
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
                    .tint(.red)
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
                    TalkGroupPill(title: talkCaption, action: openGroups)
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
                .multilineTextAlignment(.center)
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(.orange)
        .opacity(session.speakerLine.isEmpty ? 0 : 1)
        .accessibilityHidden(session.speakerLine.isEmpty)
    }

    private func talkButton(side: CGFloat) -> some View {
        let glass: Glass = session.isTalking
            ? .regular.tint(.red).interactive()
            : .regular.interactive()
        return ZStack {
            Circle()
                .fill(Color.red.opacity(session.isTalking ? (colorScheme == .dark ? 0.55 : 0.38) : 0))
                .blur(radius: 46)
                .frame(width: side * 0.92, height: side * 0.92)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Image(systemName: session.isTalking ? "waveform" : "mic.fill")
                    .font(.system(size: side * 0.2, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: session.isTalking)
                    .foregroundStyle(session.isTalking ? Color.red : Color.primary)
                Text(session.isTalking ? "Snakker…" : "Hold for å snakke")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
            }
            .padding(28)
            .frame(width: side, height: side)
            .glassEffect(glass, in: Circle())
        }
        .opacity(session.canTransmit ? 1 : 0.45)
        .scaleEffect(session.isTalking ? 1.04 : 1)
        .animation(.smooth(duration: 0.22), value: session.isTalking)
        .contentShape(Circle())
        .highPriorityGesture(talkGesture)
        .allowsHitTesting(session.canTransmit)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(session.isTalking ? "Snakker" : "Hold for å snakke")
        .accessibilityHint("Hold inne for å snakke. Med VoiceOver aktiverer du for å starte og stoppe. Hold volum opp inne for å snakke.")
        .accessibilityAction {
            if session.isTalking {
                session.endTransmitting()
            } else {
                session.beginTransmitting()
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: session.isTalking)
    }

    private var talkCaption: String {
        let match = session.groups.first { $0.id == session.talkGroup }
        let label = match?.name ?? session.room
        if label.isEmpty { return "Ingen gruppe" }
        return "Snakker i: \(label)"
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
                Circle()
                    .fill(Color.red.opacity(0.22))
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)
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

    private var talkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in session.beginTransmitting() }
            .onEnded { _ in session.endTransmitting() }
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
            .font(.subheadline.weight(.medium))
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
                            .glassEffect(.regular.tint(.red), in: Circle())
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
                        .tint(.red)
                    LegalLinks(server: session.serverURL)
                    Button(action: signUp) {
                        Text("Opprett konto")
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
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
                .tint(.red)
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
                .font(.headline)
            Text(fromLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Godta") { session.replyInvite(room: invite.room, accept: true) }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                Button("Avslå") { session.replyInvite(room: invite.room, accept: false) }
                    .buttonStyle(.glass)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var fromLine: String {
        if invite.fromName.isEmpty { return "Invitasjon" }
        return "Fra \(invite.fromName)"
    }
}

private struct GroupList: View {
    @ObservedObject var session: WalkieSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(session.groups) { group in
                GroupRow(session: session, group: group)
            }
        }
    }
}

private struct GroupRow: View {
    @ObservedObject var session: WalkieSession
    let group: WalkieGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(group.name)
                    .font(.headline)
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
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Fjern \(group.name)")
            }
            Toggle("Lytt", isOn: listenBinding)
            if group.admin {
                AdminTools(session: session, group: group)
            }
            RosterList(session: session, group: group)
            ProblemLine(text: session.joinProblem(for: group.id))
            MemberList(session: session, groupID: group.id)
            PresenceCaption(text: session.presenceCaption(for: group.id))
        }
        .padding(12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var talkTitle: String {
        session.talkGroup == group.id ? "Snakk" : "Velg"
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
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct MemberLine: View {
    let member: OnlineMember

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(label)
                .font(nameFont)
                .foregroundStyle(nameColor)
        }
    }

    private var label: String {
        member.talking ? "\(member.name) snakker" : member.name
    }

    private var nameFont: Font {
        member.talking ? .body.weight(.bold) : .body
    }

    private var nameColor: Color {
        member.talking ? .orange : .primary
    }
}

private struct WalkieBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    var transmitting: Bool

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [
                SIMD2(0, 0), SIMD2(0.5, 0), SIMD2(1, 0),
                SIMD2(0, 0.55), SIMD2(0.5, 0.48), SIMD2(1, 0.58),
                SIMD2(0, 1), SIMD2(0.5, 1), SIMD2(1, 1)
            ],
            colors: colors
        )
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.35), value: transmitting)
    }

    private var colors: [Color] {
        if colorScheme == .dark {
            if transmitting {
                return [
                    Color(white: 0.05), Color(red: 0.28, green: 0.03, blue: 0.04), Color(white: 0.07),
                    Color(red: 0.20, green: 0.03, blue: 0.05), Color(red: 0.62, green: 0.06, blue: 0.08), Color(red: 0.18, green: 0.03, blue: 0.04),
                    Color(white: 0.04), Color(red: 0.24, green: 0.04, blue: 0.05), Color(white: 0.06)
                ]
            }
            return [
                Color(white: 0.07), Color(white: 0.09), Color(red: 0.16, green: 0.08, blue: 0.09),
                Color(white: 0.06), Color(red: 0.18, green: 0.08, blue: 0.09), Color(white: 0.08),
                Color(white: 0.05), Color(white: 0.10), Color(red: 0.11, green: 0.07, blue: 0.09)
            ]
        }
        if transmitting {
            return [
                Color(red: 1, green: 0.94, blue: 0.92), Color(red: 1, green: 0.78, blue: 0.74), Color(red: 1, green: 0.91, blue: 0.89),
                Color(red: 1, green: 0.84, blue: 0.81), Color(red: 1, green: 0.48, blue: 0.44), Color(red: 1, green: 0.82, blue: 0.79),
                Color(red: 0.98, green: 0.93, blue: 0.94), Color(red: 1, green: 0.86, blue: 0.84), Color(red: 0.97, green: 0.91, blue: 0.93)
            ]
        }
        return [
            Color(red: 0.96, green: 0.95, blue: 0.98), Color(red: 1, green: 0.94, blue: 0.93), Color(red: 0.99, green: 0.90, blue: 0.90),
            Color(red: 0.93, green: 0.94, blue: 0.99), Color(red: 1, green: 0.89, blue: 0.87), Color(red: 0.96, green: 0.93, blue: 0.97),
            Color(red: 0.90, green: 0.93, blue: 0.97), Color(red: 0.97, green: 0.94, blue: 0.95), Color(red: 0.94, green: 0.91, blue: 0.94)
        ]
    }
}

private extension View {
    func glassFieldChrome() -> some View {
        self
            .textFieldStyle(.plain)
            .tint(.red)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

#Preview {
    ContentView()
}
