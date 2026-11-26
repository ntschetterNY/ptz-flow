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
    /// The final exact landing uses the camera's own absolute move at this speed (1 = slowest ... 24).
    public var landingSpeed: Int = 4
    /// Speed used when the camera's position can't be read and it is simply sent to the end point.
    public var blindSpeed: Int = 10
    /// How long the landing may take before giving up (seconds).
    public var landingTimeout: Double = 12
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

    /// Close enough to call it "on the end point" (a couple of VISCA units).
    public static func isOnTarget(_ a: Pose, _ b: Pose) -> Bool {
        abs(a.pan - b.pan) <= 2 && abs(a.tilt - b.tilt) <= 2 && abs(a.zoom - b.zoom) <= 16
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

/// Plays moves on a camera: a smooth glide by streaming small speed commands along the easing curve,
/// then a guaranteed landing with the camera's own absolute-position move, so it always ends exactly on the
/// saved end point even when the speed calibration is off.
public final class MoveEngine: @unchecked Sendable {
    public let camera: PTZCamera
    public var calibration: MotionCalibration
    /// Called when a move has measured how fast the camera really goes, so the app can save it.
    public var onCalibrationLearned: (@Sendable (MotionCalibration) -> Void)?

    public enum Outcome: Equatable, Sendable {
        case arrived
        case cancelled
        /// Couldn't read the camera's position; the camera was sent straight to the end point instead.
        case sentWithoutFeedback
        /// The camera stopped moving short of the end point.
        case stoppedShort(Pose)
    }

    public init(camera: PTZCamera, calibration: MotionCalibration = MotionCalibration()) {
        self.camera = camera
        self.calibration = calibration
    }

    /// Runs a whole move. Most moves are just "go to the end point"; a start point (A) is optional.
    @discardableResult
    public func perform(_ move: Move, progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Outcome {
        guard var current = await readPose() else {
            camera.moveAbsolute(to: move.end, speed: calibration.blindSpeed)
            progress(1)
            return .sentWithoutFeedback
        }
        if let start = move.start, !MotionMath.isClose(current, start, calibration: calibration) {
            await glide(from: current, to: start, duration: Self.repositionTime(current, start), easing: .silk) { _ in }
            if Task.isCancelled { camera.stopAll(); return .cancelled }
            current = await readPose() ?? start
        }
        if !MotionMath.isClose(current, move.end, calibration: calibration) {
            await glide(from: current, to: move.end, duration: move.duration, easing: move.easing, progress: progress)
        }
        if Task.isCancelled { camera.stopAll(); return .cancelled }
        let outcome = await land(on: move.end)
        progress(1)
        return outcome
    }

    /// A smooth move from wherever the camera is to `pose` (used by "Go").
    @discardableResult
    public func moveTo(_ pose: Pose, duration: Double? = nil, easing: Easing = .silk,
                       progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Outcome {
        var move = Move(id: "go", name: "Go", end: pose, duration: 0, easing: easing)
        if let current = await readPose() {
            move.duration = duration ?? Self.repositionTime(current, pose)
        }
        return await perform(move, progress: progress)
    }

    /// Off-air repositioning time: quick, but still eased. 1 to 3 seconds depending on distance.
    static func repositionTime(_ a: Pose, _ b: Pose) -> Double {
        let d = max(Double(abs(a.pan - b.pan)) / 1500, Double(abs(a.tilt - b.tilt)) / 900, Double(abs(a.zoom - b.zoom)) / 6000)
        return min(max(1.0 + d, 1.0), 3.0)
    }

    /// A position read that tolerates a dropped UDP reply.
    func readPose(attempts: Int = 3) async -> Pose? {
        for _ in 0..<attempts {
            if let p = await camera.readPose() { return p }
            if Task.isCancelled { return nil }
        }
        return nil
    }

    func glide(from: Pose, to: Pose, duration: Double, easing: Easing, progress: @Sendable (Double) -> Void) async {
        let c = calibration
        let interval = 1.0 / max(c.tickRate, 1)
        var shaper = AxisShaper(calibration: c)
        var learner = CalibrationLearner(start: from)
        let started = Date()
        var tick = 0

        while !Task.isCancelled {
            let elapsed = Date().timeIntervalSince(started)
            let p = duration > 0 ? min(elapsed / duration, 1) : 1
            progress(p * 0.97) // the landing finishes the bar
            if p >= 1 { break }
            let now = MotionMath.target(from: from, to: to, duration: duration, easing: easing, progress: p)
            let lagged = MotionMath.target(from: from, to: to, duration: duration, easing: easing,
                                           progress: duration > 0 ? max((elapsed - c.latency) / duration, 0) : 1)
            let measured = await camera.readPose()
            if let measured { learner.observe(measured) }
            let v = MotionMath.velocity(target: lagged.pose, panVelocity: now.panVelocity, tiltVelocity: now.tiltVelocity,
                                        zoomVelocity: now.zoomVelocity, measured: measured, calibration: c)
            let cmd = shaper.shape(v, dt: interval)
            camera.drive(panSpeed: cmd.panStep, tiltSpeed: cmd.tiltStep, zoomSpeed: cmd.zoomStep)
            learner.commanded(cmd, dt: interval)
            tick += 1
            await Self.sleep(until: started.addingTimeInterval(Double(tick) * interval))
        }
        // Ease the speed down rather than cutting it, then hand over to the landing.
        while !Task.isCancelled, !shaper.isAtRest {
            let cmd = shaper.shape(MotionMath.Velocity(pan: 0, tilt: 0, zoom: 0), dt: interval)
            camera.drive(panSpeed: cmd.panStep, tiltSpeed: cmd.tiltStep, zoomSpeed: cmd.zoomStep)
            learner.commanded(cmd, dt: interval)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        camera.stopAll()
        if !Task.isCancelled, let end = await camera.readPose() {
            learner.observe(end)
            let learned = learner.updated(c)
            if learned != c {
                calibration = learned
                onCalibrationLearned?(learned)
            }
        }
    }

    /// Finishes exactly on `target` with the camera's own absolute move at a slow speed. Usually the glide has
    /// already got within a few units, so this is a tiny, invisible correction. Waits until the camera arrives
    /// or stops moving.
    func land(on target: Pose) async -> Outcome {
        let c = calibration
        guard var last = await readPose() else {
            camera.moveAbsolute(to: target, speed: c.landingSpeed)
            return .sentWithoutFeedback
        }
        if MotionMath.isOnTarget(last, target) { camera.stopAll(); return .arrived }
        camera.moveAbsolute(to: target, speed: c.landingSpeed)
        var still = 0
        let deadline = Date().addingTimeInterval(c.landingTimeout)
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard let p = await camera.readPose() else { continue }
            if MotionMath.isOnTarget(p, target) { return .arrived }
            still = (p == last) ? still + 1 : 0
            last = p
            if still >= 8 { // not moving for 0.8 s: ask once more, firmly
                camera.moveAbsolute(to: target, speed: c.blindSpeed)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if let q = await readPose(), MotionMath.isOnTarget(q, target) { return .arrived }
                return .stoppedShort(await readPose() ?? last)
            }
        }
        if Task.isCancelled { camera.stopAll(); return .cancelled }
        return .stoppedShort(last)
    }

    /// Sleeps to an absolute deadline so a slow position reply doesn't stretch the whole move.
    static func sleep(until deadline: Date) async {
        let wait = deadline.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
    }
}

/// Learns how far the camera really moves per speed step, from what a move commanded vs. what it measured.
/// The starting numbers are guesses; after a couple of moves the glide lands close and the final correction
/// is tiny.
public struct CalibrationLearner: Sendable {
    private let start: Pose
    private var latest: Pose
    private var panStepSeconds = 0.0
    private var tiltStepSeconds = 0.0
    private var zoomStepSeconds = 0.0

    public init(start: Pose) {
        self.start = start
        latest = start
    }

    public mutating func observe(_ pose: Pose) { latest = pose }

    public mutating func commanded(_ cmd: MotionMath.Command, dt: Double) {
        panStepSeconds += Double(cmd.panStep) * dt
        tiltStepSeconds += Double(cmd.tiltStep) * dt
        zoomStepSeconds += Double(cmd.zoomStep) * dt
    }

    /// Blends each measured rate halfway into the calibration, ignoring tiny moves and wild readings.
    public func updated(_ c: MotionCalibration) -> MotionCalibration {
        var out = c
        func blend(_ old: Double, moved: Int, stepSeconds: Double, minStepSeconds: Double) -> Double {
            guard abs(stepSeconds) >= minStepSeconds, moved != 0, (Double(moved) > 0) == (stepSeconds > 0) else { return old }
            let measured = Double(moved) / stepSeconds
            let clamped = min(max(measured, old / 4), old * 4)
            return (old + clamped) / 2
        }
        out.panUnitsPerSecondPerStep = blend(c.panUnitsPerSecondPerStep, moved: latest.pan - start.pan,
                                             stepSeconds: panStepSeconds, minStepSeconds: 20)
        out.tiltUnitsPerSecondPerStep = blend(c.tiltUnitsPerSecondPerStep, moved: latest.tilt - start.tilt,
                                              stepSeconds: tiltStepSeconds, minStepSeconds: 20)
        out.zoomUnitsPerSecondPerStep = blend(c.zoomUnitsPerSecondPerStep, moved: latest.zoom - start.zoom,
                                              stepSeconds: zoomStepSeconds, minStepSeconds: 4)
        return out
    }
}
