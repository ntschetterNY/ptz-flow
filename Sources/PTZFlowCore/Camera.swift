import Foundation

/// What the motion engine needs from a camera. Speeds are signed: positive pan = right,
/// positive tilt = up, positive zoom = tele. (Directions are a guess until checked on the camera.)
public protocol PTZCamera: AnyObject, Sendable {
    func readPose() async -> Pose?
    func drive(panSpeed: Int, tiltSpeed: Int, zoomSpeed: Int)
    func stopAll()
    func setAutoFocus(_ on: Bool)
    func onePushFocus()
}

/// A BirdDog PTZ camera controlled over VISCA-over-IP.
public final class BirdDogCamera: PTZCamera, @unchecked Sendable {
    public let host: String
    private let client: VISCAClient
    private var lastZoomSpeed = Int.min
    private var lastPanTilt = (Int.min, Int.min)
    private var lastPanTiltSent = Date.distantPast
    private let lock = NSLock()
    private let inquiries = AsyncMutex()

    public init(host: String, port: UInt16 = VISCA.defaultPort) {
        self.host = host
        client = VISCAClient(host: host, port: port)
        client.start()
    }

    deinit {
        client.stop()
    }

    public func readPose() async -> Pose? {
        // One position query at a time: the move loop, tracking and "Set A/B" may all ask.
        await inquiries.acquire()
        defer { Task { await inquiries.release() } }
        guard let ptReply = await client.inquire(VISCA.panTiltPositionInquiry),
              let pt = VISCA.parsePanTilt(ptReply),
              let zReply = await client.inquire(VISCA.zoomPositionInquiry),
              let z = VISCA.parseZoom(zReply) else {
            return nil
        }
        return Pose(pan: pt.pan, tilt: pt.tilt, zoom: z)
    }

    public func drive(panSpeed: Int, tiltSpeed: Int, zoomSpeed: Int) {
        lock.lock(); defer { lock.unlock() }
        // Don't flood the camera with identical speed commands; resend now and then in case a UDP packet was lost.
        let now = Date()
        if (panSpeed, tiltSpeed) == lastPanTilt, now.timeIntervalSince(lastPanTiltSent) < 0.5 {
            sendZoomIfChanged(zoomSpeed)
            return
        }
        lastPanTilt = (panSpeed, tiltSpeed)
        lastPanTiltSent = now
        let panDir: VISCA.PanDirection = panSpeed > 0 ? .right : (panSpeed < 0 ? .left : .stop)
        let tiltDir: VISCA.TiltDirection = tiltSpeed > 0 ? .up : (tiltSpeed < 0 ? .down : .stop)
        client.command(VISCA.panTiltDriveExtended(panSpeed: abs(panSpeed), tiltSpeed: abs(tiltSpeed), pan: panDir, tilt: tiltDir))
        sendZoomIfChanged(zoomSpeed)
    }

    private func sendZoomIfChanged(_ zoomSpeed: Int) {
        if zoomSpeed != lastZoomSpeed {
            client.command(VISCA.zoomVariableExtended(speed: zoomSpeed))
            lastZoomSpeed = zoomSpeed
        }
    }

    public func stopAll() {
        lock.lock(); defer { lock.unlock() }
        client.command(VISCA.panTiltStop)
        client.command(VISCA.zoomStop)
        lastZoomSpeed = 0
        lastPanTilt = (0, 0)
        lastPanTiltSent = Date()
    }

    public func setAutoFocus(_ on: Bool) {
        client.command(VISCA.focusMode(auto: on))
    }

    public func onePushFocus() {
        client.command(VISCA.onePushAutoFocus)
    }

    /// Quick, non-eased reposition (used before a move with a start point).
    public func jump(to pose: Pose) {
        client.command(VISCA.absolutePanTilt(pan: pose.pan, tilt: pose.tilt, panSpeed: 20, tiltSpeed: 18))
        client.command(VISCA.zoomDirect(pose.zoom))
    }
}

/// Lets async callers take turns.
actor AsyncMutex {
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    func release() {
        if queue.isEmpty {
            busy = false
        } else {
            queue.removeFirst().resume()
        }
    }
}
