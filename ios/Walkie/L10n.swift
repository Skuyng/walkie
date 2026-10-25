import Foundation

/// In-app language. A saved choice wins. Otherwise English if the device
/// prefers English, Norwegian for nb/nn/no, and Norwegian for anything else.
enum AppLanguage: String, CaseIterable, Identifiable {
    case nb
    case en

    var id: String { rawValue }

    var locale: Locale {
        Locale(identifier: self == .en ? "en" : "nb")
    }

    static func resolved(stored: String?) -> AppLanguage {
        if stored == AppLanguage.en.rawValue { return .en }
        if stored == AppLanguage.nb.rawValue { return .nb }
        return deviceDefault
    }

    static var deviceDefault: AppLanguage {
        for identifier in Locale.preferredLanguages {
            let code = identifier.lowercased()
            if code.hasPrefix("en") { return .en }
            if code.hasPrefix("nb") || code.hasPrefix("nn") || code.hasPrefix("no") { return .nb }
        }
        return .nb
    }
}

enum LinkCopy: Equatable {
    case disconnected
    case signingIn
    case connecting
    case signedIn
    case connected
    case reconnecting

    var key: LKey {
        switch self {
        case .disconnected: return .disconnected
        case .signingIn: return .signingIn
        case .connecting: return .connecting
        case .signedIn: return .signedIn
        case .connected: return .connected
        case .reconnecting: return .reconnecting
        }
    }
}

/// User-facing audio failures. The engine reports a case; the session localizes it.
enum AudioAlert: Equatable {
    case noInput
    case failedToStart
    case microphoneDenied
    case stopped
    case interrupted
    case routeChanged
    case mediaReset

    var key: LKey {
        switch self {
        case .noInput: return .noMicrophone
        case .failedToStart: return .audioFailed
        case .microphoneDenied: return .microphoneDenied
        case .stopped: return .audioStopped
        case .interrupted: return .audioInterrupted
        case .routeChanged: return .audioRoute
        case .mediaReset: return .audioReset
        }
    }
}

enum AppNotice: Equatable {
    case key(LKey)
    case audio(AudioAlert)
    case phrase(String)
    case room(String, String)
}

enum LKey {
    case disconnected
    case signingIn
    case connecting
    case signedIn
    case connected
    case reconnecting
    case acceptTerms
    case usernameRule
    case enterName
    case passwordRule
    case enterGroupName
    case signIn
    case enterUsername
    case cannotContactSelf
    case needGroup
    case badServer
    case reportSent
    case accountDeleted
    case loginAgain
    case somethingWrong
    case notInGroup
    case noMicrophone
    case audioFailed
    case microphoneDenied
    case audioStopped
    case audioInterrupted
    case audioRoute
    case audioReset
    case microphone
    case headsUp
    case ok
    case openSettings
    case settings
    case noGroup
    case darkTalking
    case darkMode
    case tapToExit
    case talkHint
    case nobodyOnline
    case oneOnline
    case manyOnline
    case replayFrom
    case nameTalking
    case speakerOn
    case speakerOff
    case listenSpeaker
    case listenEarpiece
    case listenMuted
    case incomingVolume
    case volume
    case addContact
    case connect
    case cancel
    case disconnect
    case groups
    case directSection
    case oneMember
    case manyMembers
    case contacts
    case quietHours
    case account
    case about
    case done
    case server
    case fromTime
    case toTime
    case quietCaption
    case language
    case username
    case usernamePlaceholder
    case password
    case passwordPlaceholder
    case createUser
    case privacy
    case back
    case displayName
    case displayNamePlaceholder
    case acceptTermsToggle
    case creatingAccount
    case groupNamePlaceholder
    case optionalPassword
    case createGroup
    case askToJoin
    case join
    case invites
    case accept
    case decline
    case invitation
    case fromPerson
    case searchUser
    case waitingFor
    case wantsDirect
    case requestSent
    case adminBadge
    case removeNamed
    case listen
    case report
    case endDirect
    case channelDeletesBoth
    case send
    case reportStored
    case unblock
    case block
    case reportAsk
    case online
    case offline
    case endDirectAsk
    case select
    case invite
    case savePassword
    case removePassword
    case newPassword
    case asksToJoin
    case remove
    case removeAsk
    case memberLosesAccess
    case terms
    case logOut
    case deleteAccount
    case deleteAccountAsk
    case deleteAccountBody
    case transmitting
    case receiving
    case opensSettings
    case opensChannels
    case roomLine
    case speakingIn
    case speakingTail
}

enum L10n {
    static func text(_ key: LKey, _ language: AppLanguage) -> String {
        let english = language == .en
        switch key {
        case .disconnected: return english ? "Not connected" : "Ikke tilkoblet"
        case .signingIn: return english ? "Signing in…" : "Logger inn…"
        case .connecting: return english ? "Connecting…" : "Kobler til…"
        case .signedIn: return english ? "Signed in" : "Innlogget"
        case .connected: return english ? "Connected" : "Tilkoblet"
        case .reconnecting: return english ? "Disconnected – trying again…" : "Frakoblet – prøver igjen…"
        case .acceptTerms: return english ? "You must accept the terms." : "Du må godta vilkårene."
        case .usernameRule: return english ? "The username must be 3–20 characters (a–z, 0–9)." : "Brukernavnet må være 3–20 tegn (a–z, 0–9)."
        case .enterName: return english ? "Enter a name." : "Skriv et navn."
        case .passwordRule: return english ? "The password must be at least 4 characters." : "Passordet må ha minst 4 tegn."
        case .enterGroupName: return english ? "Enter a group name." : "Skriv et gruppenavn."
        case .signIn: return english ? "Log in" : "Logg inn"
        case .enterUsername: return english ? "Enter a username." : "Skriv et brukernavn."
        case .cannotContactSelf: return english ? "You can't contact yourself." : "Du kan ikke kontakte deg selv."
        case .needGroup: return english ? "Create a group, or start a direct conversation." : "Opprett en gruppe, eller start en direkte samtale."
        case .badServer: return english ? "The server address must be ws:// or wss://." : "Serveradressen må være ws:// eller wss://."
        case .reportSent: return english ? "The report was sent." : "Rapporten er sendt."
        case .accountDeleted: return english ? "The account was deleted." : "Kontoen er slettet."
        case .loginAgain: return english ? "Log in again." : "Logg inn på nytt."
        case .somethingWrong: return english ? "Something went wrong" : "Noe gikk galt"
        case .notInGroup: return english ? "Not in the group" : "Ikke med i gruppen"
        case .noMicrophone: return english ? "Couldn't find a microphone." : "Fant ingen mikrofon."
        case .audioFailed: return english ? "Couldn't start audio." : "Fikk ikke startet lyden."
        case .microphoneDenied: return english ? "TalkNet can't use the microphone. Open Settings and turn on Microphone for TalkNet." : "TalkNet får ikke bruke mikrofonen. Åpne Innstillinger og slå på Mikrofon for TalkNet."
        case .audioStopped: return english ? "Audio stopped and couldn't be started again." : "Lyden stoppet og kunne ikke startes igjen."
        case .audioInterrupted: return english ? "Audio was interrupted and couldn't be started again." : "Lyden ble avbrutt og kunne ikke startes igjen."
        case .audioRoute: return english ? "The audio output changed, and audio couldn't be started again." : "Lydutgangen endret seg, og lyden kunne ikke startes igjen."
        case .audioReset: return english ? "Audio was reset and couldn't be started again." : "Lyden ble tilbakestilt og kunne ikke startes igjen."
        case .microphone: return english ? "Microphone" : "Mikrofon"
        case .headsUp: return english ? "Notice" : "Obs"
        case .ok: return "OK"
        case .openSettings: return english ? "Open Settings" : "Åpne Innstillinger"
        case .settings: return english ? "Settings" : "Innstillinger"
        case .noGroup: return english ? "No group" : "Ingen gruppe"
        case .darkTalking: return english ? "Dark mode. Talking." : "Mørk modus. Snakker."
        case .darkMode: return english ? "Dark mode" : "Mørk modus"
        case .tapToExit: return english ? "Tap to exit" : "Trykk for å avslutte"
        case .talkHint: return english ? "Hold to talk. With VoiceOver, activate to start and stop. Hold volume up to talk. The headset play button toggles sending." : "Hold inne for å snakke. Med VoiceOver aktiverer du for å starte og stoppe. Hold volum opp inne for å snakke. Hodetelefonens avspillingsknapp veksler sending."
        case .nobodyOnline: return english ? "Nobody online" : "Ingen pålogget"
        case .oneOnline: return english ? "1 online" : "1 pålogget"
        case .manyOnline: return english ? "%@ online" : "%@ pålogget"
        case .replayFrom: return english ? "Play the last message from %@, %@" : "Spill av siste melding fra %@, %@"
        case .nameTalking: return english ? "%@ is talking" : "%@ snakker"
        case .speakerOn: return english ? "Speaker on" : "Høyttaler på"
        case .speakerOff: return english ? "Speaker off" : "Høyttaler av"
        case .listenSpeaker: return english ? "Speaker" : "Høyttaler"
        case .listenEarpiece: return english ? "Earpiece" : "Øretelefon"
        case .listenMuted: return english ? "Muted" : "Dempet"
        case .incomingVolume: return english ? "Incoming volume" : "Innkommende volum"
        case .volume: return english ? "Volume" : "Volum"
        case .addContact: return english ? "Add" : "Legg til"
        case .connect: return english ? "Connect" : "Koble til"
        case .cancel: return english ? "Cancel" : "Avbryt"
        case .disconnect: return english ? "Disconnect" : "Koble fra"
        case .groups: return english ? "Groups" : "Grupper"
        case .directSection: return english ? "Direct" : "Direkte"
        case .oneMember: return english ? "1 member" : "1 medlem"
        case .manyMembers: return english ? "%@ members" : "%@ medlemmer"
        case .contacts: return english ? "Contacts" : "Kontakter"
        case .quietHours: return english ? "Do not disturb" : "Ikke forstyrr"
        case .account: return english ? "Account" : "Konto"
        case .about: return english ? "About" : "Om"
        case .done: return english ? "Done" : "Ferdig"
        case .server: return english ? "Server" : "Server"
        case .fromTime: return english ? "From" : "Fra"
        case .toTime: return english ? "To" : "Til"
        case .quietCaption: return english ? "Turn on to mute incoming audio %@. The name still shows." : "Slå på for å dempe innkommende lyd %@. Navnet vises fortsatt."
        case .language: return english ? "Language" : "Språk"
        case .username: return english ? "Username" : "Brukernavn"
        case .usernamePlaceholder: return english ? "username" : "brukernavn"
        case .password: return english ? "Password" : "Passord"
        case .passwordPlaceholder: return english ? "At least 4 characters" : "Minst 4 tegn"
        case .createUser: return english ? "Create account" : "Opprett bruker"
        case .privacy: return english ? "Privacy" : "Personvern"
        case .back: return english ? "Back" : "Tilbake"
        case .displayName: return english ? "Display name" : "Visningsnavn"
        case .displayNamePlaceholder: return english ? "The name others see" : "Navnet andre ser"
        case .acceptTermsToggle: return english ? "I accept the terms" : "Jeg godtar vilkårene"
        case .creatingAccount: return english ? "Creating account…" : "Oppretter konto…"
        case .groupNamePlaceholder: return english ? "Group name (for example Family)" : "Gruppenavn (f.eks. Familie)"
        case .optionalPassword: return english ? "Password (optional)" : "Passord (valgfritt)"
        case .createGroup: return english ? "Create group" : "Opprett gruppe"
        case .askToJoin: return english ? "Ask to join" : "Be om å bli med"
        case .join: return english ? "Join" : "Bli med"
        case .invites: return english ? "Invitations" : "Invitasjoner"
        case .accept: return english ? "Accept" : "Godta"
        case .decline: return english ? "Decline" : "Avslå"
        case .invitation: return english ? "Invitation" : "Invitasjon"
        case .fromPerson: return english ? "From %@" : "Fra %@"
        case .searchUser: return english ? "Find user" : "Søk bruker"
        case .waitingFor: return english ? "Waiting for %@" : "Venter på %@"
        case .wantsDirect: return english ? "Wants to talk directly" : "Vil snakke direkte"
        case .requestSent: return english ? "The request was sent" : "Forespørselen er sendt"
        case .adminBadge: return english ? "Admin" : "admin"
        case .removeNamed: return english ? "Remove %@" : "Fjern %@"
        case .listen: return english ? "Listen" : "Lytt"
        case .report: return english ? "Report" : "Rapporter"
        case .endDirect: return english ? "End" : "Avslutt"
        case .channelDeletesBoth: return english ? "The channel is deleted for both of you." : "Kanalen slettes for begge."
        case .send: return english ? "Send" : "Send"
        case .reportStored: return english ? "The report is stored on the server. Abuse is not tolerated." : "Rapporten lagres hos serveren. Misbruk tåles ikke."
        case .unblock: return english ? "Unblock" : "Opphev blokkering"
        case .block: return english ? "Block" : "Blokker"
        case .reportAsk: return english ? "Report %@?" : "Rapportere %@?"
        case .online: return english ? "Online" : "Pålogget"
        case .offline: return english ? "Offline" : "Ikke pålogget"
        case .endDirectAsk: return english ? "End the direct channel with %@?" : "Avslutte direkte med %@?"
        case .select: return english ? "Select" : "Velg"
        case .invite: return english ? "Invite" : "Invitér"
        case .savePassword: return english ? "Save password" : "Lagre passord"
        case .removePassword: return english ? "Remove password" : "Fjern passord"
        case .newPassword: return english ? "New password" : "Nytt passord"
        case .asksToJoin: return english ? "%@ asks to join" : "%@ ber om å bli med"
        case .remove: return english ? "Remove" : "Fjern"
        case .removeAsk: return english ? "Remove %@?" : "Fjerne %@?"
        case .memberLosesAccess: return english ? "The member loses access to the group." : "Medlemmet mister tilgang til gruppen."
        case .terms: return english ? "Terms" : "Vilkår"
        case .logOut: return english ? "Log out" : "Logg ut"
        case .deleteAccount: return english ? "Delete account" : "Slett konto"
        case .deleteAccountAsk: return english ? "Delete the account?" : "Slette kontoen?"
        case .deleteAccountBody: return english ? "The user, sessions, and memberships are deleted. Groups you own alone are deleted. Otherwise the oldest member becomes admin. This can't be undone." : "Brukeren, øktene og medlemskapene slettes. Grupper du eier alene slettes. Ellers får det eldste medlemmet admin. Dette kan ikke angres."
        case .transmitting: return english ? "Transmitting" : "Sender"
        case .receiving: return english ? "Receiving" : "Mottar"
        case .opensSettings: return english ? "Opens settings" : "Åpner innstillinger"
        case .opensChannels: return english ? "Opens channels" : "Åpner kanaler"
        case .roomLine: return "%@: %@"
        case .speakingIn: return english ? "%@ in %@" : "%@ i %@"
        case .speakingTail: return english ? "talking" : "snakker"
        }
    }

    static func format(_ key: LKey, _ language: AppLanguage, _ values: [String]) -> String {
        var result = text(key, language)
        for value in values {
            guard let range = result.range(of: "%@") else { break }
            result.replaceSubrange(range, with: value)
        }
        return result
    }

    static func notice(_ notice: AppNotice, _ language: AppLanguage) -> String {
        switch notice {
        case .key(let key):
            return text(key, language)
        case .audio(let alert):
            return text(alert.key, language)
        case .phrase(let raw):
            return phrase(raw, language)
        case .room(let label, let raw):
            return format(.roomLine, language, [label, phrase(raw, language)])
        }
    }

    /// Server messages stay Norwegian on the wire. Map the known ones for display.
    static func phrase(_ raw: String, _ language: AppLanguage) -> String {
        if language != .en { return raw }
        return englishPhrases[raw] ?? raw
    }

    private static let englishPhrases: [String: String] = [
        "Logg inn": "Log in",
        "Logg inn på nytt.": "Log in again.",
        "Brukernavnet må være 3–20 tegn (a–z, 0–9).": "The username must be 3–20 characters (a–z, 0–9).",
        "Skriv et navn.": "Enter a name.",
        "Passordet må ha minst 4 tegn.": "The password must be at least 4 characters.",
        "Du må godta vilkårene.": "You must accept the terms.",
        "Feil brukernavn eller passord": "Wrong username or password",
        "Skriv et brukernavn.": "Enter a username.",
        "Fant ikke kanalen": "Couldn't find the channel",
        "Direktekanalen er avsluttet": "The direct channel has ended",
        "Skriv et gruppenavn.": "Enter a group name.",
        "Skriv passordet.": "Enter the password.",
        "Du kan ikke fjerne deg selv.": "You can't remove yourself.",
        "Du er fjernet fra gruppen": "You were removed from the group",
        "Ikke medlem": "Not a member",
        "Ikke med i gruppen": "Not in the group",
        "Noe gikk galt": "Something went wrong",
        "Brukernavnet er opptatt": "That username is taken",
        "Gruppen finnes allerede. Be om å bli med.": "The group already exists. Ask to join.",
        "Fant ikke brukeren": "Couldn't find the user",
        "Du kan ikke invitere deg selv": "You can't invite yourself",
        "Allerede medlem": "Already a member",
        "Fant ikke invitasjonen": "Couldn't find the invitation",
        "Fant ikke gruppen": "Couldn't find the group",
        "Du har en invitasjon. Godta den i stedet.": "You have an invitation. Accept that instead.",
        "Gruppen har ikke passord. Be om å bli med.": "The group has no password. Ask to join.",
        "Feil passord": "Wrong password",
        "Admin kan ikke fjernes": "An admin can't be removed",
        "Slett gruppen i stedet.": "Delete the group instead.",
        "Du er ikke admin": "You are not an admin",
        "Du kan ikke blokkere deg selv.": "You can't block yourself.",
        "Du kan ikke rapportere deg selv.": "You can't report yourself.",
        "Du kan ikke kontakte deg selv.": "You can't contact yourself.",
        "Du kan ikke kontakte denne brukeren.": "You can't contact this user.",
        "Dere snakker allerede direkte.": "You already have a direct channel.",
        "Forespørselen er sendt.": "The request was sent.",
        "Forespørselen er sendt": "The request was sent",
        "Du har en forespørsel. Godta den.": "You have a request. Accept it.",
        "Fant ikke forespørselen": "Couldn't find the request",
        "Opprett en gruppe, eller start en direkte samtale.": "Create a group, or start a direct conversation.",
        "Serveradressen må være ws:// eller wss://.": "The server address must be ws:// or wss://.",
        "Rapporten er sendt.": "The report was sent.",
        "Kontoen er slettet.": "The account was deleted.",
        "Kontoen er stengt.": "This account is closed.",
        "Advarsel: Uakseptabel oppførsel": "Warning: Unacceptable behavior"
    ]
}
