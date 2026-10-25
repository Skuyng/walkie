import Foundation
import os

/// Events from the walkie server. Binary audio is delivered separately.
enum ServerEvent {
    case session(token: String, username: String, name: String)
    case inbox(groups: [ServerGroup], invites: [WalkieInvite], requests: [WalkieRequest])
    case users(room: String, members: [RoomMember], selfID: String)
    case talkStarted(name: String, room: String, id: String)
    case talkStopped(name: String, room: String, id: String)
    case rejected(room: String, message: String)
}

/// WebSocket client for the protocol in `server.js`.
///
/// Sign in with `{t:signup}`, `{t:login}`, or `{t:resume}`. Membership, not a
/// group password, decides who hears audio. `{t:start}` and `{t:stop}` include
/// the talk room. Binary frames stay raw PCM16.
final class WalkieSocket: NSObject, URLSessionWebSocketDelegate {
    var onOpen: (() -> Void)?
    var onClose: ((Error?) -> Void)?
    var onEvent: ((ServerEvent) -> Void)?
    var onAudio: ((Data) -> Void)?

    private let log = Logger(subsystem: "com.skuyng.walkie", category: "socket")
    private let lock = NSLock()
    private let state = SocketState()
    private lazy var urlSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.shouldUseExtendedBackgroundIdleMode = true
        configuration.timeoutIntervalForRequest = 30
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.skuyng.walkie.socket"
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }()

    func connect(url: URL) {
        let previous = withLock { state -> URLSessionWebSocketTask? in
            let existing = state.task
            state.task = nil
            state.closeReported = true
            return existing
        }
        previous?.cancel(with: .goingAway, reason: nil)

        let task = urlSession.webSocketTask(with: url)
        withLock { state in
            state.task = task
            state.closeReported = false
        }
        log.info("Connecting \(url.absoluteString, privacy: .public)")
        task.resume()
    }

    func close() {
        let previous = withLock { state -> (URLSessionWebSocketTask?, DispatchSourceTimer?) in
            let task = state.task
            let timer = state.pingTimer
            state.task = nil
            state.pingTimer = nil
            state.closeReported = true
            return (task, timer)
        }
        previous.1?.cancel()
        previous.0?.cancel(with: .goingAway, reason: nil)
    }

    func sendSignup(username: String, name: String, password: String) {
        sendEncodable(Command(t: "signup", username: username, name: name, password: password))
    }

    func sendLogin(username: String, password: String) {
        sendEncodable(Command(t: "login", username: username, password: password))
    }

    func sendResume(token: String) {
        sendEncodable(Command(t: "resume", token: token))
    }

    func sendLogout(completion: (() -> Void)? = nil) {
        sendEncodable(Command(t: "logout"), completion: completion)
    }

    func sendCreateGroup(name: String, password: String) {
        let secret = password.isEmpty ? nil : password
        sendEncodable(Command(t: "createGroup", name: name, password: secret))
    }

    func sendJoinWithPassword(name: String, password: String) {
        sendEncodable(Command(t: "joinWithPassword", name: name, password: password))
    }

    func sendSetPassword(room: String, password: String) {
        sendEncodable(Command(t: "setPassword", password: password, room: room))
    }

    func sendInvite(room: String, username: String) {
        sendEncodable(Command(t: "invite", username: username, room: room))
    }

    func sendInviteReply(room: String, accept: Bool) {
        sendEncodable(Command(t: "inviteReply", room: room, accept: accept))
    }

    func sendRequestJoin(name: String) {
        sendEncodable(Command(t: "requestJoin", name: name))
    }

    func sendRequestReply(room: String, username: String, accept: Bool) {
        sendEncodable(Command(t: "requestReply", username: username, room: room, accept: accept))
    }

    func sendRemoveMember(room: String, username: String) {
        sendEncodable(Command(t: "removeMember", username: username, room: room))
    }

    func sendLeave(room: String) {
        sendEncodable(Command(t: "leave", room: room))
    }

    func sendDeleteGroup(room: String) {
        sendEncodable(Command(t: "deleteGroup", room: room))
    }

    func sendSubscribe(talk: String, muted: [String]) {
        sendEncodable(SubscribeCommand(talk: talk, muted: muted))
    }

    func sendStart(room: String) {
        sendEncodable(Outbound(t: "start", room: room))
    }

    func sendStop(room: String) {
        sendEncodable(Outbound(t: "stop", room: room))
    }

    func send(audio: Data) {
        let task = withLock { $0.task }
        task?.send(.data(audio)) { _ in }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        let matches = withLock { $0.task === webSocketTask }
        guard matches else { return }
        log.info("WebSocket open")
        receiveNext(on: webSocketTask)
        startPing(for: webSocketTask)
        let handler = onOpen
        DispatchQueue.main.async { handler?() }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        log.info("WebSocket closed \(closeCode.rawValue, privacy: .public)")
        reportClose(of: webSocketTask, error: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let socketTask = task as? URLSessionWebSocketTask else { return }
        if let error {
            log.error("WebSocket ended: \(error.localizedDescription, privacy: .public)")
        }
        reportClose(of: socketTask, error: error)
    }

    private func sendEncodable<Message: Encodable>(_ message: Message, completion: (() -> Void)? = nil) {
        let finish: () -> Void = {
            guard let completion else { return }
            DispatchQueue.main.async(execute: completion)
        }
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else {
            finish()
            return
        }
        let task = withLock { $0.task }
        guard let task else {
            finish()
            return
        }
        task.send(.string(text)) { _ in finish() }
    }

    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            let current = self.withLock { $0.task }
            guard current === task else { return }
            switch result {
            case .failure(let error):
                self.reportClose(of: task, error: error)
            case .success(let message):
                switch message {
                case .data(let data):
                    self.onAudio?(data)
                case .string(let text):
                    if let event = Self.parse(text) {
                        let handler = self.onEvent
                        DispatchQueue.main.async { handler?(event) }
                    }
                @unknown default:
                    break
                }
                self.receiveNext(on: task)
            }
        }
    }

    private func startPing(for task: URLSessionWebSocketTask) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self, weak task] in
            guard let self, let task else { return }
            let current = self.withLock { $0.task }
            guard current === task else { return }
            task.sendPing { _ in }
        }
        var replaced: DispatchSourceTimer?
        let accepted = withLock { state -> Bool in
            guard state.task === task else { return false }
            replaced = state.pingTimer
            state.pingTimer = timer
            return true
        }
        if accepted {
            replaced?.cancel()
            timer.resume()
        } else {
            timer.cancel()
        }
    }

    private func reportClose(of task: URLSessionWebSocketTask, error: Error?) {
        let shouldReport = withLock { state -> Bool in
            guard state.task === task, !state.closeReported else { return false }
            state.closeReported = true
            state.task = nil
            return true
        }
        guard shouldReport else { return }
        let timer = withLock { state -> DispatchSourceTimer? in
            let existing = state.pingTimer
            state.pingTimer = nil
            return existing
        }
        timer?.cancel()
        let handler = onClose
        DispatchQueue.main.async { handler?(error) }
    }

    private func withLock<T>(_ body: (SocketState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(state)
    }

    private static func parse(_ text: String) -> ServerEvent? {
        guard let data = text.data(using: .utf8),
              let message = try? JSONDecoder().decode(Inbound.self, from: data) else { return nil }
        switch message.t {
        case "session":
            guard let token = message.token, let username = message.username else { return nil }
            return .session(token: token, username: username, name: message.name ?? "")
        case "inbox":
            return .inbox(groups: message.groups ?? [], invites: message.invites ?? [], requests: message.requests ?? [])
        case "users":
            return .users(
                room: message.room ?? "",
                members: members(from: message),
                selfID: message.me ?? ""
            )
        case "start":
            guard let name = message.name else { return nil }
            return .talkStarted(name: name, room: message.room ?? "", id: message.id ?? name)
        case "stop":
            guard let name = message.name else { return nil }
            return .talkStopped(name: name, room: message.room ?? "", id: message.id ?? name)
        case "error":
            let messageText = message.error ?? "Noe gikk galt"
            return .rejected(room: message.room ?? "", message: messageText)
        default:
            return nil
        }
    }

    /// Prefer the server's per-socket ids. An older server only sends names;
    /// index keeps two people with the same name as two rows.
    private static func members(from message: Inbound) -> [RoomMember] {
        if let members = message.members {
            let parsed = members.filter { !$0.id.isEmpty && !$0.name.isEmpty }
            if !parsed.isEmpty { return parsed }
        }
        return (message.users ?? []).enumerated().compactMap { index, name in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return RoomMember(id: "\(index)|\(trimmed)", name: trimmed)
        }
    }
}

private final class SocketState {
    var task: URLSessionWebSocketTask?
    var closeReported = false
    var pingTimer: DispatchSourceTimer?
}

private struct SubscribeCommand: Encodable {
    var t = "subscribe"
    var talk: String
    var muted: [String]
}

private struct Command: Encodable {
    var t: String
    var username: String?
    var name: String?
    var password: String?
    var token: String?
    var room: String?
    var accept: Bool?

    enum CodingKeys: String, CodingKey {
        case t, username, name, password, token, room, accept
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(t, forKey: .t)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encodeIfPresent(token, forKey: .token)
        try container.encodeIfPresent(room, forKey: .room)
        try container.encodeIfPresent(accept, forKey: .accept)
    }
}

private struct Inbound: Decodable {
    var t: String
    var name: String?
    var users: [String]?
    var members: [RoomMember]?
    var room: String?
    var error: String?
    var id: String?
    var me: String?
    var token: String?
    var username: String?
    var groups: [ServerGroup]?
    var invites: [WalkieInvite]?
    var requests: [WalkieRequest]?

    enum CodingKeys: String, CodingKey {
        case t, name, users, members, room, error, id, token, username, groups, invites, requests
        case me = "self"
    }
}

private struct Outbound: Encodable {
    var t: String
    var room: String
}
