import Foundation

/// How camera speed steps relate to real movement. These defaults are GUESSES:
/// run a calibration on the real camera (drive at a known step for a known time, read the position back)
/// and save the measured values.
public struct MotionCalibration: Codable, Equatable, Sendable {
    /// Pan position units per second, per extended speed step (0...255).
    public var panUnitsPerSecondPerStep: Double = 4
    /// Tilt position units per second, per extended speed step (0...255).
    public var tiltUnitsPerSecondPerStep: Double = 4
    /// Zoom position units per second, per extended zoom speed step (0...15).
    public var zoomUnitsPerSecondPerStep: Double = 250
    /// How hard the loop corrects drift between where the camera is and where it should be (per second).
    public var correctionGain: Double = 2.5
    /// Command rate in Hz.
    public var tickRate: Double = 20

    public init() {}
}

/// Turns "where the camera should be now, and how fast it should be going" into speed steps.
public enum MotionMath {
    public struct Command: Equatable, Sendable {
        public var panStep: Int
        public var tiltStep: Int
        public var zoomStep: Int
    }

    /// Target pose and velocity (units per second) at progress `p` of a move.
    public static func target(from: Pose, to: Pose, duration: Double, easing: Easing, progress p: Double)
        -> (pose: Pose, panVelocity: Double, tiltVelocity: Double, zoomVelocity: Double) {
        let pose = from.interpolated(to: to, fraction: easing.value(p))
        let rate = duration > 0 ? easing.slope(p) / duration : 0
        return (pose,
                Double(to.pan - from.pan) * rate,
                Double(to.tilt - from.tilt) * rate,
                Double(to.zoom - from.zoom) * rate)
    }

    /// Feed-forward velocity plus a proportional correction toward the target, converted to speed steps.
    public static func command(target: Pose, panVelocity: Double, tiltVelocity: Double, zoomVelocity: Double,
                               measured: Pose?, calibration c: MotionCalibration) -> Command {
        var vp = panVelocity, vt = tiltVelocity, vz = zoomVelocity
        if let m = measured {
            vp += c.correctionGain * Double(target.pan - m.pan)
            vt += c.correctionGain * Double(target.tilt - m.tilt)
            vz += c.correctionGain * Double(target.zoom - m.zoom)
        }
        return Command(
            panStep: clampStep(vp / c.panUnitsPerSecondPerStep, 255),
            tiltStep: clampStep(vt / c.tiltUnitsPerSecondPerStep, 255),
            zoomStep: clampStep(vz / c.zoomUnitsPerSecondPerStep, 15)
        )
    }

    static func clampStep(_ v: Double, _ limit: Int) -> Int {
        guard v.isFinite else { return 0 }
        return min(max(Int(v.rounded()), -limit), limit)
    }
}

/// Plays moves on a camera by streaming small speed commands along the easing curve,
/// instead of a single preset recall (which jumps at a fixed speed).
public final class MoveEngine: @unchecked Sendable {
    public let camera: PTZCamera
    public var calibration: MotionCalibration

    public init(camera: PTZCamera, calibration: MotionCalibration = MotionCalibration()) {
        self.camera = camera
        self.calibration = calibration
    }

    /// Runs a whole move. Cancel the surrounding Task to stop; the camera is always told to stop at the end.
    public func perform(_ move: Move, progress: @escaping @Sendable (Double) -> Void = { _ in }) async {
        defer { camera.stopAll() }
        guard var current = await camera.readPose() else { return }
        if let start = move.start {
            await glide(from: current, to: start, duration: 1.5, easing: .easeInOut) { _ in }
            if Task.isCancelled { return }
            current = await camera.readPose() ?? start
        }
        await glide(from: current, to: move.end, duration: move.duration, easing: move.easing, progress: progress)
    }

    func glide(from: Pose, to: Pose, duration: Double, easing: Easing, progress: @Sendable (Double) -> Void) async {
        let started = Date()
        let interval = 1.0 / max(calibration.tickRate, 1)
        while !Task.isCancelled {
            let p = duration > 0 ? min(Date().timeIntervalSince(started) / duration, 1) : 1
            progress(p)
            if p >= 1 { break }
            let t = MotionMath.target(from: from, to: to, duration: duration, easing: easing, progress: p)
            let measured = await camera.readPose()
            let cmd = MotionMath.command(target: t.pose, panVelocity: t.panVelocity, tiltVelocity: t.tiltVelocity,
                                         zoomVelocity: t.zoomVelocity, measured: measured, calibration: calibration)
            camera.drive(panSpeed: cmd.panStep, tiltSpeed: cmd.tiltStep, zoomSpeed: cmd.zoomStep)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        camera.stopAll()
    }
}
