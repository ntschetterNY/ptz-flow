import Foundation
import Network

/// A UDP VISCA-over-IP connection to one camera.
public final class VISCAClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ptzflow.visca")
    private var sequence: UInt32 = 0
    private var waiter: (([UInt8]) -> Void)?

    public init(host: String, port: UInt16 = VISCA.defaultPort) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 52381,
            using: .udp
        )
    }

    public func start() {
        connection.start(queue: queue)
        receiveLoop()
        queue.async { self.sendRaw(VISCA.resetSequencePacket) }
    }

    public func stop() {
        connection.cancel()
    }

    /// Fire-and-forget command.
    public func command(_ payload: [UInt8]) {
        queue.async {
            self.sequence &+= 1
            self.sendRaw(VISCA.packet(.command, payload: payload, sequence: self.sequence))
        }
    }

    /// Sends an inquiry and waits for its `90 50 ...` reply, or nil after `timeout` seconds.
    public func inquire(_ payload: [UInt8], timeout: TimeInterval = 0.15) async -> [UInt8]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[UInt8]?, Never>) in
            queue.async {
                let once = Once()
                let finish: ([UInt8]?) -> Void = { reply in
                    guard !once.done else { return }
                    once.done = true
                    continuation.resume(returning: reply)
                }
                self.waiter = { finish($0) }
                self.sequence &+= 1
                self.sendRaw(VISCA.packet(.inquiry, payload: payload, sequence: self.sequence))
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    if !once.done {
                        self.waiter = nil
                        finish(nil)
                    }
                }
            }
        }
    }

    private func sendRaw(_ bytes: [UInt8]) {
        connection.send(content: Data(bytes), completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count > 8 {
                self.handle(Array(data.dropFirst(8)))
            }
            if error == nil {
                self.receiveLoop()
            }
        }
    }

    /// Runs on `queue`. ACKs (`90 4y FF`) and completions (`90 5y FF`) are ignored; only inquiry replies are passed on.
    private func handle(_ payload: [UInt8]) {
        guard payload.count > 3, payload[1] == 0x50 else { return }
        let w = waiter
        waiter = nil
        w?(payload)
    }
}

private final class Once: @unchecked Sendable {
    var done = false
}
