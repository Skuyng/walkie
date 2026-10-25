import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var session = WalkieSession()
    @Environment(\.scenePhase) private var scenePhase
    @State private var darkMode = false
    @State private var savedBrightness: CGFloat?
    @State private var showMenu = false
    @State private var listenToast = ""
    @State private var showListenToast = false
    @State private var showListenVolume = false
    @State private var listenHide: Task<Void, Never>?
    @State private var volumeHide: Task<Void, Never>?

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
        .environment(\.locale, session.language.locale)
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
            syncProximity(scenePhase)
        }
        .onDisappear {
            exitDarkMode()
            volumeHide?.cancel()
            UIDevice.current.isProximityMonitoringEnabled = false
            session.setVolumeButtonMonitoringEnabled(false)
            session.setHeadsetTalkEnabled(false)
        }
        .onChange(of: session.name) { _, _ in session.savePreferences() }
        .onChange(of: session.room) { _, _ in session.savePreferences() }
        .onChange(of: session.serverURL) { _, _ in session.savePreferences() }
        .onChange(of: session.listenOutput) { _, _ in
            syncProximity(scenePhase)
        }
        .onChange(of: session.linkState) { _, _ in refreshVolumeButtons() }
        .onChange(of: session.hasConnectedOnce) { _, connected in
            if !connected { exitDarkMode() }
        }
        .onChange(of: session.signedIn) { _, signed in
            if !signed {
                showMenu = false
                hideListenVolume()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                session.endTransmitting()
                session.setCaptureWarm(false)
                session.releaseIdleVolumeSession()
                hideListenVolume()
            } else if phase == .active {
                session.setCaptureWarm(true)
                session.prepareVolumeHUD()
                session.resumeAudioIfNeeded()
            }
            syncDarkMode(with: phase)
            syncProximity(phase)
            refreshVolumeButtons()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.proximityStateDidChangeNotification)) { _ in
            refreshVolumeButtons()
        }
        .sheet(isPresented: $showMenu) {
            HomeMenu(session: session)
                .presentationBackground {
                    AuroraBackground(live: auroraLive)
                }
        }
        .alert(session.suggestsSettings ? session.t(.microphone) : session.t(.headsUp), isPresented: errorPresented) {
            Button(session.t(.ok), role: .cancel) {}
            if session.suggestsSettings {
                Button(session.t(.openSettings)) {
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
            let side = min(geo.size.width - 64, max(220, geo.size.height - 288))
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
                            session: session,
                            link: linkAction,
                            volumeOpen: showListenVolume,
                            onSpeaker: cycleListen,
                            onVolume: toggleListenVolume,
                            onDark: enterDarkMode,
                            onLink: linkTapped
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
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
            .overlay(alignment: .bottom) {
                listenChrome
                    .padding(.bottom, 92)
            }
            .overlayPreferenceValue(VolumeButtonAnchorKey.self) { rect in
                GeometryReader { proxy in
                    if showListenVolume && rect.width > 1 {
                        ListenVolumePopover(
                            session: session,
                            anchor: rect,
                            bounds: proxy.size,
                            onDismiss: hideListenVolume,
                            onInteract: pokeListenVolume
                        )
                    }
                }
                .allowsHitTesting(showListenVolume)
            }
        }
    }

    private var homeTopBar: some View {
        VStack(spacing: 20) {
            TalkNetWordmark(mark: 28, titleFont: .title3.weight(.semibold))
                .padding(.horizontal, 48)
                .frame(maxWidth: .infinity, minHeight: 40)
                .overlay(alignment: .trailing) {
                    profileButton
                }
            TuningReadout(
                code: talkCode,
                name: channelName,
                mode: radioMode,
                transmittingLabel: session.t(.transmitting),
                receivingLabel: session.t(.receiving),
                hint: session.t(.opensSettings),
                action: openMenu
            )
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity)
        }
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
        .accessibilityLabel(session.t(.settings))
    }

    private var hasAttention: Bool {
        !session.invites.isEmpty || !session.directRequests.isEmpty || !session.requests.isEmpty
    }

    private func openMenu() {
        showMenu = true
    }

    private var listenChrome: some View {
        VStack(spacing: 8) {
            if showListenToast && !listenToast.isEmpty {
                Text(listenToast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func cycleListen() {
        session.cycleListenOutput()
        listenToast = session.listenModeTitle
        showListenToast = true
        scheduleListenHide()
    }

    /// Earpiece blanks the screen at the ear. Speaker, mute, and a real
    /// background transition turn the sensor off. A proximity blank is not
    /// backgrounding: volume-up hold-to-talk stays armed.
    private func syncProximity(_ phase: ScenePhase) {
        let atEar = session.listenOutput == .earpiece && phase != .background
        UIDevice.current.isProximityMonitoringEnabled = atEar
    }

    private func scheduleListenHide() {
        listenHide?.cancel()
        listenHide = Task {
            try? await Task.sleep(for: .seconds(1.3))
            guard !Task.isCancelled else { return }
            showListenToast = false
        }
    }

    private func toggleListenVolume() {
        if showListenVolume {
            hideListenVolume()
        } else {
            showListenVolume = true
            scheduleVolumeHide()
        }
    }

    private func hideListenVolume() {
        volumeHide?.cancel()
        volumeHide = nil
        showListenVolume = false
    }

    /// Dragging counts as interaction, so the ten-second hide starts over.
    private func pokeListenVolume() {
        guard showListenVolume else { return }
        scheduleVolumeHide()
    }

    private func scheduleVolumeHide() {
        volumeHide?.cancel()
        volumeHide = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            showListenVolume = false
        }
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
        if label.isEmpty { return session.t(.noGroup) }
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
        .accessibilityLabel(session.isTalking ? session.t(.darkTalking) : session.t(.darkMode))
        .accessibilityHint(session.t(.tapToExit))
        .accessibilityAction { exitDarkMode() }
    }

    private func enterDarkMode() {
        hideListenVolume()
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
        if scenePhase == .active || volumeHoldArmed {
            session.prepareVolumeHUD()
        }
        session.setVolumeButtonMonitoringEnabled(volumeHoldArmed)
        session.setHeadsetTalkEnabled(session.linkState == .connected)
    }

    /// Volume-up listens in the foreground, and also while earpiece mode has
    /// only turned the screen off. The app switcher and background do not.
    private var volumeHoldArmed: Bool {
        guard session.linkState == .connected else { return false }
        if scenePhase == .active { return true }
        if scenePhase == .background { return false }
        return session.listenOutput == .earpiece && UIDevice.current.proximityState
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
            .accessibilityHint(session.t(.talkHint))
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
                SpeakingName(text: session.speakerLine)
            }
        }
        .font(.system(.subheadline, design: .monospaced).weight(.medium))
        .foregroundStyle(Aurora.teal)
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .accessibilityHidden(session.speakerLine.isEmpty)
    }

    private var faceRow: some View {
        ZStack {
            HStack(spacing: 8) {
                if session.linkState == .connected && !members.isEmpty {
                    HStack(spacing: -8) {
                        ForEach(shownMembers) { member in
                            PresenceFace(member: member, talkingLabel: session.tf(.nameTalking, member.name))
                        }
                    }
                    Text(countText)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(session.centerStatus)
                } else {
                    HStack(spacing: 6) {
                        if showLinkDot {
                            LinkDot(reconnecting: session.linkState != .disconnected)
                        }
                        Text(idleText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.trailing, session.heardClip(in: session.talkGroup) == nil ? 0 : 40)
            if let clip = session.heardClip(in: session.talkGroup) {
                HStack {
                    Spacer(minLength: 0)
                    ReplayButton(label: session.tf(.replayFrom, clip.sender, clip.at.formatted(date: .omitted, time: .shortened))) {
                        session.replayLast(in: session.talkGroup)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 32)
    }

    private var showLinkDot: Bool {
        switch session.linkState {
        case .disconnected, .connecting, .reconnecting:
            return true
        case .connected, .signedIn:
            return false
        }
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
        if session.linkState == .connected { return session.t(.nobodyOnline) }
        return session.statusText
    }
}

private struct SpeakingName: View {
    var text: String
    @State private var dim = false

    var body: some View {
        Label(text, systemImage: "speaker.wave.2.fill")
            .labelStyle(.titleAndIcon)
            .symbolEffect(.variableColor.iterative)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .opacity(dim ? 0.55 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

private struct ReplayButton: View {
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Aurora.teal)
                .frame(width: 32, height: 32)
                .background {
                    Circle().fill(Color.white.opacity(0.14))
                }
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct LinkDot: View {
    var reconnecting: Bool
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(reconnecting ? Aurora.teal : Color.red)
            .frame(width: 8, height: 8)
            .opacity(reconnecting && dim ? 0.35 : 1)
            .onAppear(perform: pulse)
            .onChange(of: reconnecting) { _, _ in pulse() }
            .accessibilityHidden(true)
    }

    private func pulse() {
        dim = false
        guard reconnecting else { return }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            dim = true
        }
    }
}

private struct PresenceFace: View {
    let member: OnlineMember
    var talkingLabel: String

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
            .accessibilityLabel(member.talking ? talkingLabel : member.name)
    }

    private var initial: String {
        let trimmed = member.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "?" }
        return String(first).uppercased()
    }
}

private struct TalkBottomBar: View {
    @ObservedObject var session: WalkieSession
    var link: HomeLink
    var volumeOpen: Bool
    var onSpeaker: () -> Void
    var onVolume: () -> Void
    var onDark: () -> Void
    var onLink: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TalkIconButton(
                systemImage: session.listenSymbol,
                title: session.listenModeTitle,
                tint: speakerTint,
                action: onSpeaker
            )
            Button(action: onVolume) {
                Text(volumeLabel)
                    .font(.system(size: 20, weight: .semibold).monospacedDigit())
                    .foregroundStyle(volumeOpen ? Aurora.teal : .primary)
                    .lineLimit(1)
                    .frame(width: 80, height: 48)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.t(.incomingVolume))
            .accessibilityValue(volumeLabel)
            .background(volumeAnchor)
            TalkIconButton(systemImage: "moon.fill", title: session.t(.darkMode), tint: .primary, action: onDark)
            if link == .connect {
                Button(action: onLink) {
                    Text(session.t(.connect))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Aurora.teal)
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.t(.connect))
            } else {
                TalkIconButton(systemImage: linkIcon, title: linkTitle, tint: linkTint, action: onLink)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: Capsule())
        .accessibilityElement(children: .contain)
    }

    private var volumeLabel: String {
        "\(Int((session.listenGain * 100).rounded())) %"
    }

    private var volumeAnchor: some View {
        GeometryReader { proxy in
            Color.clear.preference(key: VolumeButtonAnchorKey.self, value: proxy.frame(in: .named("talk")))
        }
        .allowsHitTesting(false)
    }

    private var speakerTint: Color {
        switch session.listenOutput {
        case .speaker:
            return .primary
        case .earpiece:
            return Aurora.teal
        case .mute:
            return .secondary
        }
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
            return session.t(.connect)
        case .cancel:
            return session.t(.cancel)
        case .disconnect:
            return session.t(.disconnect)
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

private struct VolumeButtonAnchorKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.width > 0 {
            value = next
        }
    }
}

/// Full-screen layer so the slider's frame sits inside a parent that can hit-test it.
/// An offset overlay on the short bottom bar drew the capsule but never received the drag.
private struct ListenVolumePopover: View {
    @ObservedObject var session: WalkieSession
    var anchor: CGRect
    var bounds: CGSize
    var onDismiss: () -> Void
    var onInteract: () -> Void

    private static let gap: CGFloat = 10
    private static let blockWidth: CGFloat = 64
    private static let blockHeight: CGFloat = 172

    var body: some View {
        ZStack {
            Color.white.opacity(0.001)
                .frame(width: bounds.width, height: bounds.height)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
            VStack(spacing: 6) {
                Text(percentLabel)
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onInteract)
                VerticalListenSlider(session: session, onInteract: onInteract)
            }
            .frame(width: Self.blockWidth, height: Self.blockHeight)
            .position(x: centerX, y: centerY)
        }
        .frame(width: bounds.width, height: bounds.height)
    }

    private var percentLabel: String {
        "\(Int((session.listenGain * 100).rounded()))%"
    }

    private var centerX: CGFloat {
        let half = Self.blockWidth / 2
        let lower = half + 8
        let upper = max(lower, bounds.width - half - 8)
        return min(max(anchor.midX, lower), upper)
    }

    private var centerY: CGFloat {
        let half = Self.blockHeight / 2
        let preferred = anchor.minY - Self.gap - half
        return max(preferred, half + 8)
    }
}

/// Owns the step counter so a gain update does not rebuild the drag gesture.
/// Main-actor: the drag runs on the UI thread and writes the session gain.
@MainActor
private final class VolumeDragActions {
    var set: @MainActor (Double) -> Void = { _ in }
    var lastStep = -1

    static let steps = 20

    static func step(for gain: Double) -> Int {
        Int((min(1, max(0, gain)) * Double(steps)).rounded())
    }

    func apply(gain: Double, session: WalkieSession, onInteract: () -> Void) {
        session.setListenGain(gain)
        onInteract()
        let next = Self.step(for: session.listenGain)
        guard next != lastStep else { return }
        lastStep = next
        session.haptics.tickVolume()
    }
}

private struct VerticalListenSlider: View {
    @ObservedObject var session: WalkieSession
    var onInteract: () -> Void
    @State private var actions = VolumeDragActions()

    private static let trackWidth: CGFloat = 44
    private static let trackHeight: CGFloat = 140

    var body: some View {
        ZStack {
            VolumeLevelTrack(
                fraction: session.listenGain,
                width: Self.trackWidth,
                height: Self.trackHeight
            )
            VolumeDragTarget(
                width: Self.trackWidth,
                height: Self.trackHeight,
                actions: actions
            )
            .equatable()
        }
        .frame(width: Self.trackWidth, height: Self.trackHeight)
        .accessibilityElement()
        .accessibilityLabel(session.t(.incomingVolume))
        .accessibilityValue(percentLabel)
        .accessibilityAdjustableAction { direction in
            let delta = direction == .increment ? 0.05 : -0.05
            actions.apply(gain: session.listenGain + delta, session: session, onInteract: onInteract)
        }
        .onAppear(perform: bind)
    }

    private var percentLabel: String {
        "\(Int((session.listenGain * 100).rounded()))%"
    }

    private func bind() {
        actions.lastStep = VolumeDragActions.step(for: session.listenGain)
        let session = session
        let onInteract = onInteract
        actions.set = { [actions] gain in
            actions.apply(gain: gain, session: session, onInteract: onInteract)
        }
    }
}

private struct VolumeLevelTrack: View {
    var fraction: Double
    var width: CGFloat
    var height: CGFloat

    /// #3EE6D0
    private static let level = Color(red: 62.0 / 255.0, green: 230.0 / 255.0, blue: 208.0 / 255.0)

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.06))
                .frame(width: width, height: height)
                .glassEffect(.regular, in: Capsule())
                .overlay(alignment: .bottom) {
                    Capsule()
                        .fill(Self.level)
                        .frame(width: max(0, width - 8), height: filledHeight)
                        .padding(.bottom, 4)
                }
                .clipShape(Capsule())
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }

    private var filledHeight: CGFloat {
        let clamped = CGFloat(min(1, max(0, fraction)))
        let inner = max(0, height - 8)
        let filled = inner * clamped
        let nub: CGFloat = clamped > 0 ? 10 : 0
        return max(nub, filled)
    }
}

/// Stable hit target. Equality ignores the level so publishing gain does not cancel the drag.
private struct VolumeDragTarget: View, Equatable {
    var width: CGFloat
    var height: CGFloat
    var actions: VolumeDragActions

    static func == (lhs: VolumeDragTarget, rhs: VolumeDragTarget) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height
    }

    var body: some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Capsule())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let span = max(height, 1)
                        let y = min(max(0, value.location.y), span)
                        actions.set(1 - Double(y / span))
                    }
            )
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
                        SettingsBlock(session.t(.language)) {
                            Picker(session.t(.language), selection: language) {
                                Text("Norsk").tag(AppLanguage.nb)
                                Text("English").tag(AppLanguage.en)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                        SettingsBlock(session.t(.groups)) {
                            GroupEditor(session: session)
                        }
                        SettingsBlock(session.t(.contacts)) {
                            DirectSection(session: session)
                        }
                        SettingsBlock(session.t(.quietHours)) {
                            QuietHoursSection(session: session)
                        }
                        SettingsBlock(session.t(.account)) {
                            VStack(alignment: .leading, spacing: 16) {
                                accountHeader
                                AccountFooter(session: session, onLogOut: logOut)
                            }
                        }
                        SettingsBlock(session.t(.about)) {
                            VStack(alignment: .leading, spacing: 16) {
                                TalkNetWordmark(mark: 28, titleFont: .title3.weight(.semibold))
                                LegalLinks(
                                    server: session.serverURL,
                                    privacyTitle: session.t(.privacy),
                                    termsTitle: session.t(.terms)
                                )
                                serverField
                                Text("Created by ™ Skutle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary.opacity(0.75))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(16)
                    .padding(.bottom, 8)
                }
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(session.t(.settings))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(session.t(.done)) { dismiss() }
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

    private var language: Binding<AppLanguage> {
        Binding(
            get: { session.language },
            set: { session.setLanguage($0) }
        )
    }

    private var displayName: String {
        if session.name.isEmpty { return session.accountUsername }
        return session.name
    }

    private var serverField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.t(.server))
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

private struct QuietHoursSection: View {
    @ObservedObject var session: WalkieSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(session.t(.quietHours), isOn: enabled)
                .font(.body.weight(.semibold))
            DatePicker(session.t(.fromTime), selection: fromDate, displayedComponents: .hourAndMinute)
                .font(.subheadline.weight(.semibold))
            DatePicker(session.t(.toTime), selection: toDate, displayedComponents: .hourAndMinute)
                .font(.subheadline.weight(.semibold))
            Text(session.tf(.quietCaption, session.quietHoursLabel))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { session.quietHoursEnabled },
            set: { session.setQuietHoursEnabled($0) }
        )
    }

    private var fromDate: Binding<Date> {
        Binding(
            get: { WalkieSession.date(fromMinutes: session.quietFromMinutes) },
            set: { session.setQuietFrom($0) }
        )
    }

    private var toDate: Binding<Date> {
        Binding(
            get: { WalkieSession.date(fromMinutes: session.quietToMinutes) },
            set: { session.setQuietTo($0) }
        )
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
        ZStack(alignment: .bottom) {
            ScrollView {
                loginFields
                    .padding(.bottom, 36)
            }
            Text("Created by ™ Skutle")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.38))
                .padding(.bottom, 12)
                .allowsHitTesting(false)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if username.isEmpty { username = session.accountUsername }
        }
    }

    private var loginFields: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                logo
                    labeledField(session.t(.username)) {
                        TextField(session.t(.usernamePlaceholder), text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .submitLabel(.next)
                            .focused($focus, equals: .username)
                            .onSubmit { focus = .password }
                            .glassFieldChrome()
                    }
                    labeledField(session.t(.password)) {
                        SecureField(session.t(.passwordPlaceholder), text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit(logIn)
                            .glassFieldChrome()
                    }
                    Button(action: logIn) {
                        Text(session.t(.signIn))
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Aurora.teal)
                    .controlSize(.large)
                    .disabled(busy)
                    Button(session.t(.createUser), action: { showSignUp = true })
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                    Button(session.t(.privacy), action: openPrivacy)
                        .buttonStyle(.plain)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    if busy {
                        Text(session.t(.signingIn))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        Button(session.t(.cancel)) { session.cancelAccountConnect() }
                            .buttonStyle(.glass)
                            .frame(maxWidth: .infinity)
                    }
            }
            .padding(24)
        }
    }

    private var logo: some View {
        VStack(spacing: 16) {
            Image("TalkNetLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Color(red: 62 / 255, green: 230 / 255, blue: 208 / 255).opacity(0.45), radius: 18, y: 4)
            TalkNetWordmark(mark: 28, titleFont: .largeTitle.weight(.bold))
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
                        Label(session.t(.back), systemImage: "chevron.left")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    Text(session.t(.createUser))
                        .font(.title2.weight(.semibold))
                    labeledField(session.t(.username)) {
                        TextField(session.t(.usernamePlaceholder), text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.username)
                            .submitLabel(.next)
                            .focused($focus, equals: .username)
                            .onSubmit { focus = .displayName }
                            .glassFieldChrome()
                    }
                    labeledField(session.t(.displayName)) {
                        TextField(session.t(.displayNamePlaceholder), text: $displayName)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.next)
                            .focused($focus, equals: .displayName)
                            .onSubmit { focus = .password }
                            .glassFieldChrome()
                    }
                    labeledField(session.t(.password)) {
                        SecureField(session.t(.passwordPlaceholder), text: $password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.newPassword)
                            .submitLabel(.go)
                            .focused($focus, equals: .password)
                            .onSubmit(signUp)
                            .glassFieldChrome()
                    }
                    Toggle(session.t(.acceptTermsToggle), isOn: $acceptedTerms)
                        .tint(Aurora.teal)
                    LegalLinks(
                        server: session.serverURL,
                        privacyTitle: session.t(.privacy),
                        termsTitle: session.t(.terms)
                    )
                    Button(action: signUp) {
                        Text(session.t(.createUser))
                            .font(.title3.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Aurora.teal)
                    .controlSize(.large)
                    .disabled(busy || !acceptedTerms)
                    if busy {
                        Text(session.t(.creatingAccount))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                        Button(session.t(.cancel)) { session.cancelAccountConnect() }
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
            TextField(session.t(.groupNamePlaceholder), text: $draftName)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .glassFieldChrome()
            SecureField(session.t(.optionalPassword), text: $draftPassword)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .glassFieldChrome()
            HStack(spacing: 8) {
                CapsuleChoice(title: session.t(.createGroup), prominent: true, height: 48, expands: true, action: createTapped)
                CapsuleChoice(title: joinTitle, prominent: false, height: 48, expands: true, action: joinTapped)
            }
            .frame(maxWidth: .infinity)
            GroupList(session: session)
        }
    }

    private var joinTitle: String {
        draftPassword.isEmpty ? session.t(.askToJoin) : session.t(.join)
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
                Text(session.t(.invites))
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
                Button(session.t(.accept)) { session.replyInvite(room: invite.room, accept: true) }
                .buttonStyle(.glassProminent)
                .tint(Aurora.teal)
            Button(session.t(.decline)) { session.replyInvite(room: invite.room, accept: false) }
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraCard()
    }

    private var fromLine: String {
        if invite.fromName.isEmpty { return session.t(.invitation) }
        return session.tf(.fromPerson, invite.fromName)
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
            if !session.contactNote.isEmpty {
                Text(L10n.phrase(session.contactNote, session.language))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .center, spacing: 8) {
                TextField(session.t(.username), text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .textContentType(nil)
                    .writingToolsBehavior(.disabled)
                    .submitLabel(.search)
                    .onSubmit(search)
                    .glassFieldChrome()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: FieldHeightKey.self, value: proxy.size.height)
                        }
                    }
                CapsuleChoice(
                    title: session.t(.searchUser),
                    prominent: false,
                    height: fieldHeight,
                    expands: false,
                    action: search
                )
            }
            .onPreferenceChange(FieldHeightKey.self) { height in
                if height > 0 { fieldHeight = height }
            }
            ForEach(session.userMatches) { match in
                UserMatchRow(session: session, match: match)
            }
            ForEach(session.directRequests) { request in
                DirectRequestRow(session: session, request: request)
            }
            ForEach(session.groups.filter(\.direct)) { group in
                GroupRow(session: session, group: group)
            }
        }
    }

    private func search() {
        session.searchUsers(raw: username)
    }
}

private struct UserMatchRow: View {
    @ObservedObject var session: WalkieSession
    let match: UserMatch

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if showsHandle {
                    Text("@\(match.username)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if match.state == "add" {
                Button(session.t(.addContact)) {
                    session.addContact(username: match.username)
                }
                .buttonStyle(.glassProminent)
                .tint(Aurora.teal)
            } else {
                Text(status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .auroraCard()
    }

    private var title: String {
        let trimmed = match.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "@\(match.username)" }
        return trimmed
    }

    private var showsHandle: Bool {
        !match.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var status: String {
        switch match.state {
        case "sent":
            return L10n.phrase("Forespørselen er sendt.", session.language)
        case "incoming":
            return L10n.phrase("Du har en forespørsel. Godta den.", session.language)
        case "contact":
            return L10n.phrase("Dere snakker allerede direkte.", session.language)
        case "blocked":
            return L10n.phrase("Du kan ikke kontakte denne brukeren.", session.language)
        case "self":
            return L10n.phrase("Du kan ikke kontakte deg selv.", session.language)
        default:
            return ""
        }
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
                    Button(session.t(.accept)) { session.replyDirect(username: request.username, accept: true) }
                        .buttonStyle(.glassProminent)
                        .tint(Aurora.teal)
                    Button(session.t(.decline)) { session.replyDirect(username: request.username, accept: false) }
                        .buttonStyle(.glass)
                } else {
                    Button(session.t(.cancel)) { session.replyDirect(username: request.username, accept: false) }
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
        request.incoming ? person : session.tf(.waitingFor, person)
    }

    private var detail: String {
        request.incoming ? session.t(.wantsDirect) : session.t(.requestSent)
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
                        .accessibilityLabel(session.t(.password))
                }
                if group.admin {
                    Text(session.t(.adminBadge))
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
                .accessibilityLabel(session.tf(.removeNamed, group.name))
            }
            Toggle(session.t(.listen), isOn: listenBinding)
            if group.direct && !group.peer.isEmpty {
                HStack(spacing: 8) {
                    Button(blockTitle) { session.setBlocked(group.peer, !session.isBlocked(group.peer)) }
                        .buttonStyle(.glass)
                    Button(session.t(.report)) { confirmReport = true }
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
            Button(session.t(.endDirect), role: .destructive, action: remove)
            Button(session.t(.cancel), role: .cancel) {}
        } message: {
            Text(session.t(.channelDeletesBoth))
        }
        .alert(reportTitle, isPresented: $confirmReport) {
            Button(session.t(.send), action: reportPeer)
            Button(session.t(.cancel), role: .cancel) {}
        } message: {
            Text(session.t(.reportStored))
        }
    }

    private var blockTitle: String {
        session.isBlocked(group.peer) ? session.t(.unblock) : session.t(.block)
    }

    private var reportTitle: String {
        session.tf(.reportAsk, group.name)
    }

    private func reportPeer() {
        session.report(username: group.peer, room: group.id)
    }

    private var onlineLabel: String {
        session.peerIsOnline(in: group.id) ? session.t(.online) : session.t(.offline)
    }

    private var directTitle: String {
        session.tf(.endDirectAsk, group.name)
    }

    private var talkTitle: String {
        session.talkGroup == group.id ? "Talk" : session.t(.select)
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
                TextField(session.t(.username), text: $inviteName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(invite)
                    .glassFieldChrome()
                Button(session.t(.invite), action: invite)
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
                Button(session.t(.savePassword), action: save)
                    .buttonStyle(.glass)
                if locked {
                    Button(session.t(.removePassword), action: clear)
                        .buttonStyle(.glass)
                }
            }
        }
    }

    private var placeholder: String {
        locked ? session.t(.newPassword) : session.t(.optionalPassword)
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
                Button(session.t(.accept)) { session.replyRequest(room: request.room, username: request.username, accept: true) }
                    .buttonStyle(.glassProminent)
                    .tint(.red)
                Button(session.t(.decline)) { session.replyRequest(room: request.room, username: request.username, accept: false) }
                    .buttonStyle(.glass)
            }
        }
    }

    private var requestLabel: String {
        session.tf(.asksToJoin, "\(request.displayName) (@\(request.username))")
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
                    Button(session.t(.report)) { confirmReport = true }
                        .buttonStyle(.glass)
                }
                if canRemove {
                    Button(session.t(.remove)) { confirmRemove = true }
                        .buttonStyle(.glass)
                }
            }
        }
        .alert(reportTitle, isPresented: $confirmReport) {
            Button(session.t(.send), action: report)
            Button(session.t(.cancel), role: .cancel) {}
        } message: {
            Text(session.t(.reportStored))
        }
        .confirmationDialog(confirmTitle, isPresented: $confirmRemove, titleVisibility: .visible) {
            Button(session.t(.remove), role: .destructive, action: remove)
            Button(session.t(.cancel), role: .cancel) {}
        } message: {
            Text(session.t(.memberLosesAccess))
        }
    }

    private var reportTitle: String {
        session.tf(.reportAsk, memberLine)
    }

    private var blockTitle: String {
        session.isBlocked(member.username) ? session.t(.unblock) : session.t(.block)
    }

    private var confirmTitle: String {
        session.tf(.removeAsk, memberLine)
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
    var privacyTitle: String
    var termsTitle: String

    var body: some View {
        HStack(spacing: 16) {
            Button(privacyTitle) { open("/personvern") }
            Button(termsTitle) { open("/vilkar") }
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
            Button(session.t(.logOut), action: onLogOut)
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
            Button(session.t(.deleteAccount)) { confirmDelete = true }
                .buttonStyle(.glass)
                .tint(.red)
                .frame(maxWidth: .infinity)
        }
        .confirmationDialog(session.t(.deleteAccountAsk), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(session.t(.deleteAccount), role: .destructive) { session.deleteAccount() }
            Button(session.t(.cancel), role: .cancel) {}
        } message: {
            Text(session.t(.deleteAccountBody))
        }
    }
}

private struct MemberList: View {
    @ObservedObject var session: WalkieSession
    let groupID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(session.onlineMembers(in: groupID)) { member in
                MemberLine(member: member, talkingText: session.tf(.nameTalking, member.name))
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
    var talkingText: String

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
        member.talking ? talkingText : member.name
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
