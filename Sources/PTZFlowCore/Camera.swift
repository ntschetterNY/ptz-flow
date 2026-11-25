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

    public init(host: String, port: UInt16 = VISCA.defaultPort) {
        self.host = host
        client = VISCAClient(host: host, port: port)
        client.start()
    }

    deinit {
        client.stop()
    }

    public func readPose() async -> Pose? {
        guard let ptReply = await client.inquire(VISCA.panTiltPositionInquiry),
              let pt = VISCA.parsePanTilt(ptReply),
              let zReply = await client.inquire(VISCA.zoomPositionInquiry),
              let z = VISCA.parseZoom(zReply) else {
            return nil
        }
        return Pose(pan: pt.pan, tilt: pt.tilt, zoom: z)
    }

    public func drive(panSpeed: Int, tiltSpeed: Int, zoomSpeed: Int) {
        let panDir: VISCA.PanDirection = panSpeed > 0 ? .right : (panSpeed < 0 ? .left : .stop)
        let tiltDir: VISCA.TiltDirection = tiltSpeed > 0 ? .up : (tiltSpeed < 0 ? .down : .stop)
        client.command(VISCA.panTiltDriveExtended(panSpeed: abs(panSpeed), tiltSpeed: abs(tiltSpeed), pan: panDir, tilt: tiltDir))
        if zoomSpeed != lastZoomSpeed {
            client.command(VISCA.zoomVariableExtended(speed: zoomSpeed))
            lastZoomSpeed = zoomSpeed
        }
    }

    public func stopAll() {
        client.command(VISCA.panTiltStop)
        client.command(VISCA.zoomStop)
        lastZoomSpeed = 0
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
