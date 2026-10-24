import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var session = WalkieSession()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focus: Field?
    @State private var darkMode = false
    @State private var savedBrightness: CGFloat?

    private enum Field: Hashable {
        case name, room, server
    }

    var body: some View {
        ZStack {
            WalkieBackdrop(transmitting: session.isTalking)
            if session.hasConnectedOnce {
                talkScreen
            } else {
                loginScreen
            }
            hiddenVolumeSlider
            if darkMode {
                darkOverlay
            }
        }
        .statusBarHidden(darkMode)
        .persistentSystemOverlays(darkMode ? .hidden : .automatic)
        .onAppear { refreshVolumeButtons() }
        .onDisappear {
            exitDarkMode()
            session.setVolumeButtonMonitoringEnabled(false)
        }
        .onChange(of: session.name) { _, _ in session.savePreferences() }
        .onChange(of: session.room) { _, _ in session.savePreferences() }
        .onChange(of: session.serverURL) { _, _ in session.savePreferences() }
        .onChange(of: session.linkState) { _, _ in refreshVolumeButtons() }
        .onChange(of: session.hasConnectedOnce) { _, connected in
            if !connected { exitDarkMode() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                session.endTransmitting()
            } else if phase == .active {
                session.resumeAudioIfNeeded()
            }
            syncDarkMode(with: phase)
            refreshVolumeButtons()
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

    private var loginScreen: some View {
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
                        Text("Samme kanal som nettsiden.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 4)

                    labeledField("Navn") {
                        TextField("Ditt navn", text: $session.name)
                            .textContentType(.name)
                            .textInputAutocapitalization(.words)
                            .submitLabel(.next)
                            .focused($focus, equals: .name)
                            .onSubmit { focus = .room }
                            .glassFieldChrome()
                    }

                    labeledField("Kanalkode") {
                        TextField("Kanalkode (f.eks. familie)", text: $session.room)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.next)
                            .focused($focus, equals: .room)
                            .onSubmit { focus = .server }
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
                }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var talkScreen: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 48, max(200, geo.size.height - 360))
            GlassEffectContainer(spacing: 12) {
                VStack(spacing: 16) {
                    Label("Kanal: \(session.room)", systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect(.regular, in: Capsule())

                    Label(session.statusText, systemImage: statusSymbol)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)

                    speakerRow
                        .frame(minHeight: 32)

                    Spacer(minLength: 8)

                    talkButton(side: side)

                    Spacer(minLength: 8)

                    Label(session.usersLine, systemImage: "person.2.fill")
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Label("Hold volum opp inne for å snakke", systemImage: "speaker.wave.2.fill")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    #if DEBUG
                    volumeDebugLine()
                    #endif

                    HStack(spacing: 16) {
                        Button(action: enterDarkMode) {
                            Label("Mørk modus", systemImage: "moon.fill")
                        }
                        .buttonStyle(.glass)
                        .accessibilityHint("Svart skjerm med lav lysstyrke. Trykk skjermen for å avslutte.")

                        Button(role: .destructive, action: session.disconnect) {
                            Label("Koble fra", systemImage: "phone.down.fill")
                        }
                        .buttonStyle(.glass)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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

    private var statusSymbol: String {
        switch session.linkState {
        case .connected:
            return "checkmark.circle.fill"
        case .connecting:
            return "ellipsis.circle.fill"
        case .reconnecting:
            return "arrow.triangle.2.circlepath"
        case .disconnected:
            return "circle.slash"
        }
    }

    #if DEBUG
    private func volumeDebugLine(onDark: Bool = false) -> some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let elapsed: String
            if session.volumeEventCount == 0 {
                elapsed = "—"
            } else {
                let ms = Int(timeline.date.timeIntervalSince(session.lastVolumeEvent) * 1000)
                elapsed = "\(max(0, ms))"
            }
            Text("vol \(elapsed) ms · \(session.volumeEventCount)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(onDark ? Color.white.opacity(0.55) : Color.secondary)
        }
    }
    #endif

    private var hiddenVolumeSlider: some View {
        HiddenSystemVolumeView(session: session)
            .frame(width: 80, height: 24)
            .fixedSize()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
            #if DEBUG
            volumeDebugLine(onDark: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 28)
                .allowsHitTesting(false)
            #endif
            hiddenVolumeSlider
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
