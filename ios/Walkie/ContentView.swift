import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var session = WalkieSession()
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case name, room, server
    }

    var body: some View {
        ZStack {
            Color.walkieBackground.ignoresSafeArea()
            if session.hasConnectedOnce {
                talkScreen
            } else {
                loginScreen
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: session.name) { _, _ in session.savePreferences() }
        .onChange(of: session.room) { _, _ in session.savePreferences() }
        .onChange(of: session.serverURL) { _, _ in session.savePreferences() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                session.endTransmitting()
            } else if phase == .active {
                session.resumeAudioIfNeeded()
            }
        }
        .alert("Obs", isPresented: errorPresented) {
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
            VStack(alignment: .leading, spacing: 16) {
                VStack(spacing: 8) {
                    Text("📻 Walkie-Talkie")
                        .font(.largeTitle.weight(.bold))
                    Text("Samme kanal som nettsiden.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

                fieldLabel("Navn")
                TextField("Ditt navn", text: $session.name)
                    .textFieldStyle(.plain)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.next)
                    .focused($focus, equals: .name)
                    .onSubmit { focus = .room }
                    .fieldChrome()

                fieldLabel("Kanalkode")
                TextField("Kanalkode (f.eks. familie)", text: $session.room)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .room)
                    .onSubmit { focus = .server }
                    .fieldChrome()

                fieldLabel("Server")
                TextField(WalkieSession.defaultServerURL, text: $session.serverURL)
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .submitLabel(.go)
                    .focused($focus, equals: .server)
                    .onSubmit { session.connect() }
                    .fieldChrome()

                Button(action: session.connect) {
                    Text(session.linkState == .connecting ? "Kobler til…" : "Koble til")
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.walkieRed)
                .disabled(session.linkState == .connecting || session.linkState == .reconnecting)
                .padding(.top, 8)

                if session.linkState == .connecting || session.linkState == .reconnecting {
                    Text(session.statusText)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(.secondary)
                    Button("Avbryt") { session.disconnect() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var talkScreen: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 20, geo.size.height * 0.52)
            VStack(spacing: 14) {
                Text("Kanal: \(session.room)")
                    .font(.title2.weight(.semibold))
                Text(session.statusText)
                    .foregroundStyle(.secondary)
                Text(session.speakerLine)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.walkieYellow)
                    .frame(minHeight: 34)
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(session.speakerLine.isEmpty)

                Spacer(minLength: 8)

                ZStack {
                    Circle()
                        .fill(session.isTalking ? Color.walkieGreen : Color.walkieRed)
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
                    Text(session.isTalking ? "Snakker…" : "Hold for å snakke")
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.5)
                        .padding(24)
                        .frame(width: side, height: side)
                }
                .opacity(session.canTransmit ? 1 : 0.45)
                .scaleEffect(session.isTalking ? 1.04 : 1)
                .animation(.easeOut(duration: 0.08), value: session.isTalking)
                .contentShape(Circle())
                .gesture(talkGesture)
                .allowsHitTesting(session.canTransmit)
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(session.isTalking ? "Snakker" : "Hold for å snakke")
                .accessibilityHint("Hold inne for å snakke. Med VoiceOver aktiverer du for å starte og stoppe.")
                .accessibilityAction {
                    if session.isTalking {
                        session.endTransmitting()
                    } else {
                        session.beginTransmitting()
                    }
                }
                .sensoryFeedback(.impact(weight: .medium), trigger: session.isTalking)

                Spacer(minLength: 8)

                Text(session.usersLine)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button("Koble fra", role: .destructive) {
                    session.disconnect()
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var talkGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in session.beginTransmitting() }
            .onEnded { _ in session.endTransmitting() }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.dismissError() } }
        )
    }
}

private extension View {
    func fieldChrome() -> some View {
        self
            .padding(14)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
            .tint(Color.walkieRed)
    }
}

private extension Color {
    static let walkieBackground = Color(red: 17 / 255, green: 17 / 255, blue: 17 / 255)
    static let walkieRed = Color(red: 0.80, green: 0.133, blue: 0.133)
    static let walkieGreen = Color(red: 0.133, green: 0.80, blue: 0.133)
    static let walkieYellow = Color(red: 1, green: 0.80, blue: 0)
}

#Preview {
    ContentView()
}
