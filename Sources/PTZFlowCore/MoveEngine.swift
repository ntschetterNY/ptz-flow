import Foundation

/// How camera speed steps relate to real movement, and how gently the motion loop is allowed to react.
/// The unit conversions are GUESSES until measured on the real camera (drive at a known step for a known
/// time, read the position back). The smoothing limits are taste: lower = silkier but slower to correct.
public struct MotionCalibration: Codable, Equatable, Sendable {
    /// Pan position units per second, per extended speed step (0...255).
    public var panUnitsPerSecondPerStep: Double = 4
    /// Tilt position units per second, per extended speed step (0...255).
    public var tiltUnitsPerSecondPerStep: Double = 4
    /// Zoom position units per second, per extended zoom speed step (0...15).
    public var zoomUnitsPerSecondPerStep: Double = 250
    /// How hard the loop corrects drift between where the camera is and where it should be (per second).
    public var correctionGain: Double = 1.6
    /// Errors smaller than this are left alone, so the loop never "hunts" around the curve.
    public var panTiltDeadband: Double = 4
    public var zoomDeadband: Double = 40
    /// Corrections are capped so they nudge the move instead of fighting it (units per second).
    public var maxPanTiltCorrection: Double = 240
    public var maxZoomCorrection: Double = 900
    /// How quickly a commanded speed may change (speed steps per second). This is the anti-jerk limit.
    public var panTiltAcceleration: Double = 420
    public var zoomAcceleration: Double = 24
    /// Time between asking for the camera's position and getting it back, plus motor lag (seconds).
    /// The loop compares the reading with where the camera *should have been* that long ago.
    public var latency: Double = 0.08
    /// At the end of a move the loop eases out any leftover error, for at most this long (seconds).
    public var settleTime: Double = 1.2
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

    /// Velocities in speed steps (not yet rounded), before smoothing.
    public struct Velocity: Equatable, Sendable {
        public var pan: Double
        public var tilt: Double
        public var zoom: Double
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

    /// Feed-forward velocity plus a gentle, capped correction toward the target, in (fractional) speed steps.
    public static func velocity(target: Pose, panVelocity: Double, tiltVelocity: Double, zoomVelocity: Double,
                                measured: Pose?, calibration c: MotionCalibration) -> Velocity {
        var vp = panVelocity, vt = tiltVelocity, vz = zoomVelocity
        if let m = measured {
            vp += correction(Double(target.pan - m.pan), c.panTiltDeadband, c.maxPanTiltCorrection, c.correctionGain)
            vt += correction(Double(target.tilt - m.tilt), c.panTiltDeadband, c.maxPanTiltCorrection, c.correctionGain)
            vz += correction(Double(target.zoom - m.zoom), c.zoomDeadband, c.maxZoomCorrection, c.correctionGain)
        }
        return Velocity(pan: vp / c.panUnitsPerSecondPerStep,
                        tilt: vt / c.tiltUnitsPerSecondPerStep,
                        zoom: vz / c.zoomUnitsPerSecondPerStep)
    }

    /// Same as `velocity`, rounded and clamped to what the camera accepts.
    public static func command(target: Pose, panVelocity: Double, tiltVelocity: Double, zoomVelocity: Double,
                               measured: Pose?, calibration c: MotionCalibration) -> Command {
        let v = velocity(target: target, panVelocity: panVelocity, tiltVelocity: tiltVelocity,
                         zoomVelocity: zoomVelocity, measured: measured, calibration: c)
        return Command(panStep: clampStep(v.pan, 255), tiltStep: clampStep(v.tilt, 255), zoomStep: clampStep(v.zoom, 15))
    }

    static func correction(_ error: Double, _ deadband: Double, _ cap: Double, _ gain: Double) -> Double {
        let e = softDeadzone(error, width: deadband)
        return min(max(gain * e, -cap), cap)
    }

    static func clampStep(_ v: Double, _ limit: Int) -> Int {
        guard v.isFinite else { return 0 }
        return min(max(Int(v.rounded()), -limit), limit)
    }

    public static func isClose(_ a: Pose, _ b: Pose, calibration c: MotionCalibration) -> Bool {
        abs(a.pan - b.pan) <= Int(c.panTiltDeadband * 2) &&
            abs(a.tilt - b.tilt) <= Int(c.panTiltDeadband * 2) &&
            abs(a.zoom - b.zoom) <= Int(c.zoomDeadband * 2)
    }
}

/// Rounds a stream of fractional speeds to whole steps without losing the fraction: the remainder is carried
/// into the next tick. At very slow speeds (a long prayer drift) this averages out to the exact speed
/// instead of sticking on one step and then jumping to the next.
public struct StepDitherer: Sendable {
    private var residual: Double = 0
    public let limit: Int

    public init(limit: Int) { self.limit = limit }

    public mutating func next(_ v: Double) -> Int {
        guard v.isFinite else { residual = 0; return 0 }
        if abs(v) < 0.05 { residual = 0; return 0 }
        let wanted = v + residual
        let out = min(max(Int(wanted.rounded()), -limit), limit)
        residual = min(max(wanted - Double(out), -1), 1)
        // Never reverse direction because of the carried fraction.
        if (out > 0 && v < 0) || (out < 0 && v > 0) { residual = 0; return 0 }
        return out
    }

    public mutating func reset() { residual = 0 }
}

/// Smooths speed commands on all three axes: acceleration limit, then dithered rounding.
public struct AxisShaper: Sendable {
    public var pan: SlewLimiter
    public var tilt: SlewLimiter
    public var zoom: SlewLimiter
    private var panSteps = StepDitherer(limit: 255)
    private var tiltSteps = StepDitherer(limit: 255)
    private var zoomSteps = StepDitherer(limit: 15)

    public init(calibration c: MotionCalibration) {
        pan = SlewLimiter(maxRatePerSecond: c.panTiltAcceleration)
        tilt = SlewLimiter(maxRatePerSecond: c.panTiltAcceleration)
        zoom = SlewLimiter(maxRatePerSecond: c.zoomAcceleration)
    }

    public mutating func shape(_ v: MotionMath.Velocity, dt: Double) -> MotionMath.Command {
        let p = pan.step(toward: min(max(v.pan, -255), 255), dt: dt)
        let t = tilt.step(toward: min(max(v.tilt, -255), 255), dt: dt)
        let z = zoom.step(toward: min(max(v.zoom, -15), 15), dt: dt)
        return MotionMath.Command(panStep: panSteps.next(p), tiltStep: tiltSteps.next(t), zoomStep: zoomSteps.next(z))
    }

    public var isAtRest: Bool { abs(pan.value) < 0.5 && abs(tilt.value) < 0.5 && abs(zoom.value) < 0.5 }

    public mutating func reset() {
        pan.reset(); tilt.reset(); zoom.reset()
        panSteps.reset(); tiltSteps.reset(); zoomSteps.reset()
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

    /// Runs a whole move: if it has a start point (A), glide there first, then glide to the end point (B).
    /// Cancel the surrounding Task to stop; the camera is always told to stop at the end.
    public func perform(_ move: Move, progress: @escaping @Sendable (Double) -> Void = { _ in }) async {
        defer { camera.stopAll() }
        guard var current = await camera.readPose() else { return }
        if let start = move.start, !MotionMath.isClose(current, start, calibration: calibration) {
            await glide(from: current, to: start, duration: Self.repositionTime(current, start), easing: .silk) { _ in }
            if Task.isCancelled { return }
            current = await camera.readPose() ?? start
        }
        await glide(from: current, to: move.end, duration: move.duration, easing: move.easing, progress: progress)
    }

    /// A smooth move from wherever the camera is to `pose` (used by "Go to A" / "Go to B").
    public func moveTo(_ pose: Pose, duration: Double? = nil, easing: Easing = .silk) async {
        defer { camera.stopAll() }
        guard let current = await camera.readPose() else { return }
        await glide(from: current, to: pose, duration: duration ?? Self.repositionTime(current, pose), easing: easing) { _ in }
    }

    /// Off-air repositioning time: quick, but still eased. 1 to 3 seconds depending on distance.
    static func repositionTime(_ a: Pose, _ b: Pose) -> Double {
        let d = max(Double(abs(a.pan - b.pan)) / 1500, Double(abs(a.tilt - b.tilt)) / 900, Double(abs(a.zoom - b.zoom)) / 6000)
        return min(max(1.0 + d, 1.0), 3.0)
    }

    func glide(from: Pose, to: Pose, duration: Double, easing: Easing, progress: @Sendable (Double) -> Void) async {
        let c = calibration
        let interval = 1.0 / max(c.tickRate, 1)
        var shaper = AxisShaper(calibration: c)
        let started = Date()
        var tick = 0

        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(started)
            let p = duration > 0 ? min(elapsed / duration, 1) : 1
            progress(p)
            if p >= 1 { break }
            let now = MotionMath.target(from: from, to: to, duration: duration, easing: easing, progress: p)
            let lagged = MotionMath.target(from: from, to: to, duration: duration, easing: easing,
                                           progress: duration > 0 ? max((elapsed - c.latency) / duration, 0) : 1)
            let measured = await camera.readPose()
            let v = MotionMath.velocity(target: lagged.pose, panVelocity: now.panVelocity, tiltVelocity: now.tiltVelocity,
                                        zoomVelocity: now.zoomVelocity, measured: measured, calibration: c)
            let cmd = shaper.shape(v, dt: interval)
            camera.drive(panSpeed: cmd.panStep, tiltSpeed: cmd.tiltStep, zoomSpeed: cmd.zoomStep)
            tick += 1
            await Self.sleep(until: started.addingTimeInterval(Double(tick) * interval))
        }
        if !Task.isCancelled {
            await settle(on: to, shaper: &shaper, interval: interval)
        }
        camera.stopAll()
    }

    /// Eases out whatever error is left at the end of a move, using only the (capped, dead-banded) correction.
    private func settle(on target: Pose, shaper: inout AxisShaper, interval: Double) async {
        let c = calibration
        let started = Date()
        var tick = 0
        while !Task.isCancelled, Date().timeIntervalSince(started) < c.settleTime {
            let measured = await camera.readPose()
            if let m = measured, MotionMath.isClose(m, target, calibration: c), shaper.isAtRest { break }
            let v = MotionMath.velocity(target: target, panVelocity: 0, tiltVelocity: 0, zoomVelocity: 0,
                                        measured: measured, calibration: c)
            let cmd = shaper.shape(v, dt: interval)
            camera.drive(panSpeed: cmd.panStep, tiltSpeed: cmd.tiltStep, zoomSpeed: cmd.zoomStep)
            tick += 1
            await Self.sleep(until: started.addingTimeInterval(Double(tick) * interval))
        }
    }

    /// Sleeps to an absolute deadline so a slow position reply doesn't stretch the whole move.
    static func sleep(until deadline: Date) async {
        let wait = deadline.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }
}
