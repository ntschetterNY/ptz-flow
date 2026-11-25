import Foundation
import Network

/// A tiny HTTP server on 127.0.0.1 so Stream Deck (e.g. a "Web Requests" action) or any script on this Mac
/// can trigger the app:
///
///     GET http://127.0.0.1:7350/scene/Sermon   switch Ecamm to "Sermon" and run its mapped move
///     GET http://127.0.0.1:7350/move/pulpit    run a move by id, without touching Ecamm
///     GET http://127.0.0.1:7350/stop           stop the camera where it is
///     GET http://127.0.0.1:7350/status         JSON status
///
/// It only listens on the loopback address, so nothing else on the network can reach it.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (_ route: [String]) async -> (status: Int, body: String)

    public static let defaultPort: UInt16 = 7350

    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "ptzflow.control-server")
    private var listener: NWListener?

    public init(port: UInt16 = ControlServer.defaultPort, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? 7350)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [handler] data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let route = ControlServer.route(fromRequest: text)
            Task {
                var status = 400
                var body = #"{"error":"bad request"}"#
                if let route {
                    let result = await handler(route)
                    status = result.status
                    body = result.body
                }
                let reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
                let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    /// "GET /scene/Sermon%20Close?x=1 HTTP/1.1" -> ["scene", "Sermon Close"]
    public static func route(fromRequest request: String) -> [String]? {
        guard let line = request.split(whereSeparator: \.isNewline).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "POST" else { return nil }
        let path = parts[1].split(separator: "?").first.map(String.init) ?? ""
        return path.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
    }
}
