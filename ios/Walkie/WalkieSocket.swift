import Foundation
import os

/// Events from the walkie server. Binary audio is delivered separately.
enum ServerEvent {
    case users(room: String, names: [String])
    case talkStarted(name: String, room: String)
    case talkStopped(name: String, room: String)
    case rejected(room: String, message: String)
}

struct GroupWire: Encodable {
    var room: String
    var password: String
    var create: Bool
    var listen: Bool
}

/// WebSocket client for the protocol in `server.js`.
///
/// `{t:groups}` subscribes to several rooms. `{t:join}` still selects one room
/// so an older server keeps working. `{t:start}` and `{t:stop}` include the
/// talk room. Binary frames stay raw PCM16 and are only relayed to members
/// who are allowed to hear that room.
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

    func sendGroups(name: String, talk: String, groups: [GroupWire]) {
        sendEncodable(GroupsOutbound(name: name, talk: talk, groups: groups))
    }

    func sendJoin(name: String, room: String, password: String) {
        sendEncodable(Outbound(t: "join", name: name, room: room, password: password))
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

    private func sendEncodable<Message: Encodable>(_ message: Message) {
        guard let data = try? JSONEncoder().encode(message),
              let text = String(data: data, encoding: .utf8) else { return }
        let task = withLock { $0.task }
        task?.send(.string(text)) { _ in }
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
        case "users":
            return .users(room: message.room ?? "", names: message.users ?? [])
        case "start":
            guard let name = message.name else { return nil }
            return .talkStarted(name: name, room: message.room ?? "")
        case "stop":
            guard let name = message.name else { return nil }
            return .talkStopped(name: name, room: message.room ?? "")
        case "error":
            let messageText = message.error ?? "Feil passord"
            return .rejected(room: message.room ?? "", message: messageText)
        default:
            return nil
        }
    }
}

private final class SocketState {
    var task: URLSessionWebSocketTask?
    var closeReported = false
    var pingTimer: DispatchSourceTimer?
}

private struct GroupsOutbound: Encodable {
    var t = "groups"
    var name: String
    var talk: String
    var groups: [GroupWire]
}

private struct Outbound: Encodable {
    var t: String
    var name: String?
    var room: String?
    var password: String?

    enum CodingKeys: String, CodingKey { case t, name, room, password }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(t, forKey: .t)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(room, forKey: .room)
        try container.encodeIfPresent(password, forKey: .password)
    }
}

private struct Inbound: Decodable {
    var t: String
    var name: String?
    var users: [String]?
    var room: String?
    var error: String?
}
