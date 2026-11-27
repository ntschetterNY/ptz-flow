import Foundation
import Network

/// A UDP VISCA-over-IP connection to one camera.
public final class VISCAClient: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ptzflow.visca")
    private var sequence: UInt32 = 0
    private var rtt: Double = 0.03
    /// Smoothed time for an inquiry to come back (seconds). Over a VPN this is often 50-200 ms.
    public var roundTripTime: Double { queue.sync { rtt } }
    /// The pending inquiry: the reply length it expects, and who to hand it to.
    private var waiter: (length: Int, deliver: ([UInt8]) -> Void)?

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
    /// `replyLength` filters out a late reply to an earlier inquiry (e.g. a zoom reply arriving while we wait
    /// for pan/tilt), which used to make a position read fail and a move give up.
    public func inquire(_ payload: [UInt8], replyLength: Int? = nil, timeout: TimeInterval? = nil) async -> [UInt8]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[UInt8]?, Never>) in
            queue.async {
                let once = Once()
                let sent = Date()
                // Wait long enough for a slow (VPN) link, based on how long replies have been taking.
                let wait = timeout ?? min(max(0.25, self.rtt * 3 + 0.05), 1.5)
                let finish: ([UInt8]?) -> Void = { reply in
                    guard !once.done else { return }
                    once.done = true
                    if reply != nil { self.rtt = self.rtt * 0.8 + Date().timeIntervalSince(sent) * 0.2 }
                    continuation.resume(returning: reply)
                }
                self.waiter = (replyLength ?? 0, { finish($0) })
                self.sequence &+= 1
                self.sendRaw(VISCA.packet(.inquiry, payload: payload, sequence: self.sequence))
                self.queue.asyncAfter(deadline: .now() + wait) {
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
        guard payload.count > 3, payload[1] == 0x50, let w = waiter else { return }
        if w.length > 0 && payload.count != w.length { return } // stale reply to an earlier inquiry
        waiter = nil
        w.deliver(payload)
    }
}

private final class Once: @unchecked Sendable {
    var done = false
}
