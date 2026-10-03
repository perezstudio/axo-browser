import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 that answers every request with the same page, so tests can
/// load real `http:` pages (content scripts don't run on `file:` pages) without the network.
public final class LoopbackWebServer: @unchecked Sendable {
    // @unchecked Sendable is safe here: the listener and connections are only used from `queue`,
    // and `port` is set once before `init` returns.
    private let queue = DispatchQueue(label: "LoopbackWebServer")
    private let listener: NWListener
    private let response: Data
    /// The port the server listens on.
    public private(set) var port: UInt16 = 0

    /// Starts serving `html` on a free loopback port.
    public init(html: String) async throws {
        let body = Data(html.utf8)
        response = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let queue = queue, response = response
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { _, _, _, _ in
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let listener = listener
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    deinit {
        listener.cancel()
    }

    /// A URL on this server. Each path returns the same page.
    public func url(path: String = "/") -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }
}
