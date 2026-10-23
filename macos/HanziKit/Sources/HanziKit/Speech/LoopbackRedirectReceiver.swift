import Foundation
import Network

/// Receives an OAuth redirect on a local port (RFC 8252 §7.3): the sign-in page sends the browser to
/// `http://localhost:<port>/callback?…`, and the browser gets back a short page saying how it went.
///
/// It listens on 127.0.0.1 and ::1 only, so nothing else on the network can reach it.
public final class LoopbackRedirectReceiver: @unchecked Sendable {
    public let port: UInt16
    private let queue: DispatchQueue

    // Only touched on `queue`.
    private var listeners: [NWListener] = []
    private var unread: URL?
    private var waiting: CheckedContinuation<URL, any Error>?
    private var deadline: DispatchWorkItem?
    /// The browser's /callback request, answered by `respond`.
    private var pending: NWConnection?
    private var isClosed = false

    /// Starts listening on the first of `ports` that is free.
    public static func start(ports: [UInt16]) async throws -> LoopbackRedirectReceiver {
        for port in ports {
            let receiver = LoopbackRedirectReceiver(port: port)
            if await receiver.listen() { return receiver }
        }
        throw ElevenLabsOAuthError.portsInUse
    }

    private init(port: UInt16) {
        self.port = port
        queue = DispatchQueue(label: "HanLens.loopback-redirect.\(port)")
    }

    /// Waits for the browser to arrive at /callback.
    public func nextCallback(timeout: TimeInterval = 600) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    if let url = unread {
                        unread = nil
                        continuation.resume(returning: url)
                    } else if isClosed {
                        continuation.resume(throwing: ElevenLabsOAuthError.cancelled)
                    } else {
                        waiting = continuation
                        let item = DispatchWorkItem { [weak self] in self?.endWait(.timedOut) }
                        deadline = item
                        queue.asyncAfter(deadline: .now() + timeout, execute: item)
                    }
                }
            }
        } onCancel: {
            close()
        }
    }

    /// Answers the browser's /callback request with a short page.
    public func respond(title: String, message: String) {
        queue.async { [self] in
            guard let connection = pending else { return }
            pending = nil
            send(page(title: title, message: message), status: "200 OK", on: connection)
        }
    }

    /// Stops listening; a wait in progress ends with `.cancelled`.
    public func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            listeners.forEach { $0.cancel() }
            pending?.cancel()
            pending = nil
            endWait(.cancelled)
        }
    }

    // MARK: Listening

    /// Binds both loopback addresses; false when the port is taken.
    private func listen() async -> Bool {
        guard case .success(let ipv4) = await bind("127.0.0.1") else { return false }
        switch await bind("::1") {
        case .success(let ipv6):
            queue.sync { listeners = [ipv4, ipv6] }
        case .failure(.posix(.EADDRINUSE)):
            // Something else has the IPv6 side, and a browser resolving “localhost” to ::1 would end up there.
            ipv4.cancel()
            return false
        case .failure:
            queue.sync { listeners = [ipv4] } // No IPv6 loopback on this Mac.
        }
        return true
    }

    private func bind(_ host: NWEndpoint.Host) async -> Result<NWListener, NWError> {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return .failure(error as? NWError ?? .posix(.EINVAL))
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return await withCheckedContinuation { continuation in
            let once = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume(returning: .success(listener)) }
                case .failed(let error), .waiting(let error):
                    once.run {
                        listener.cancel()
                        continuation.resume(returning: .failure(error))
                    }
                case .cancelled:
                    once.run { continuation.resume(returning: .failure(.posix(.ECANCELED))) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    // MARK: Requests (on `queue`)

    private func accept(_ connection: NWConnection) {
        guard !isClosed else { return connection.cancel() }
        connection.start(queue: queue)
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                handle(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if isComplete || error != nil || buffer.count > 32_768 {
                connection.cancel()
            } else {
                read(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ head: String, on connection: NWConnection) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[1] == "/callback" || parts[1].hasPrefix("/callback?"),
              let url = URL(string: "http://localhost:\(port)\(parts[1])") else {
            return send(page(title: "Not found", message: ""), status: "404 Not Found", on: connection)
        }
        pending?.cancel() // An older request nobody answered (e.g. a reload).
        pending = connection
        if waiting != nil {
            deliver(url)
        } else {
            unread = url
        }
    }

    private func deliver(_ url: URL) {
        deadline?.cancel()
        deadline = nil
        let continuation = waiting
        waiting = nil
        continuation?.resume(returning: url)
    }

    private func endWait(_ error: ElevenLabsOAuthError) {
        deadline?.cancel()
        deadline = nil
        let continuation = waiting
        waiting = nil
        continuation?.resume(throwing: error)
    }

    private func send(_ html: String, status: String, on connection: NWConnection) {
        let body = Data(html.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func page(title: String, message: String) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>HanLens</title><style>
        body{margin:0;min-height:100vh;display:grid;place-items:center;font:16px/1.5 -apple-system,system-ui,sans-serif;background:#f5f5f7;color:#1d1d1f}
        @media (prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}}
        main{max-width:30em;padding:0 24px;text-align:center}h1{font-size:22px;margin:0 0 8px}p{margin:0;opacity:.75}
        </style></head><body><main><h1>\(escaped(title))</h1><p>\(escaped(message))</p></main></body></html>
        """
    }
}

/// Runs its body once; only used on one serial queue.
private final class Once: @unchecked Sendable {
    private var done = false

    func run(_ body: () -> Void) {
        guard !done else { return }
        done = true
        body()
    }
}
