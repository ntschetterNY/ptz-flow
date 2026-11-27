import XCTest
import CoreGraphics
@testable import PTZFlowCore

final class EasingTests: XCTestCase {
    func testEndpoints() {
        for e in Easing.allCases {
            XCTAssertEqual(e.value(0), 0, accuracy: 1e-9, e.label)
            XCTAssertEqual(e.value(1), 1, accuracy: 1e-9, e.label)
            XCTAssertEqual(e.value(0.5), 0.5, accuracy: 1e-9, e.label)
        }
    }

    func testSmoothCurvesStartAndEndAtRest() {
        for e in [Easing.easeInOut, .gentle, .drift] {
            XCTAssertLessThan(abs(e.slope(0)), 0.05, e.label)
            XCTAssertLessThan(abs(e.slope(1)), 0.05, e.label)
        }
    }

    func testMonotonic() {
        for e in Easing.allCases {
            var last = -1.0
            for i in 0...100 {
                let v = e.value(Double(i) / 100)
                XCTAssertGreaterThanOrEqual(v, last - 1e-12)
                last = v
            }
        }
    }
}

final class VISCATests: XCTestCase {
    func testHeader() {
        let p = VISCA.packet(.command, payload: [0x81, 0x01, 0x06, 0x04, 0xFF], sequence: 0x0102_0304)
        XCTAssertEqual(p, [0x01, 0x00, 0x00, 0x05, 0x01, 0x02, 0x03, 0x04, 0x81, 0x01, 0x06, 0x04, 0xFF])
    }

    func testExtendedDriveSplitsSpeedIntoNibbles() {
        let cmd = VISCA.panTiltDriveExtended(panSpeed: 0xA7, tiltSpeed: 0x05, pan: .right, tilt: .stop)
        XCTAssertEqual(cmd, [0x81, 0x01, 0x06, 0x11, 0x0A, 0x07, 0x00, 0x05, 0x02, 0x03, 0xFF])
    }

    func testExtendedDriveClampsSpeed() {
        let cmd = VISCA.panTiltDriveExtended(panSpeed: 999, tiltSpeed: -4, pan: .left, tilt: .up)
        XCTAssertEqual(Array(cmd[4...7]), [0x0F, 0x0F, 0x00, 0x00])
    }

    func testZoomExtended() {
        XCTAssertEqual(VISCA.zoomVariableExtended(speed: 5), [0x81, 0x01, 0x04, 0x07, 0x0A, 0x02, 0x05, 0xFF])
        XCTAssertEqual(VISCA.zoomVariableExtended(speed: -20), [0x81, 0x01, 0x04, 0x07, 0x0A, 0x03, 0x0F, 0xFF])
        XCTAssertEqual(VISCA.zoomVariableExtended(speed: 0), [0x81, 0x01, 0x04, 0x07, 0x0A, 0x00, 0x00, 0xFF])
    }

    func testParsePanTiltSigned() {
        // pan = -2 (0xFFFE), tilt = 0x0123
        let reply: [UInt8] = [0x90, 0x50, 0x0F, 0x0F, 0x0F, 0x0E, 0x00, 0x01, 0x02, 0x03, 0xFF]
        let pt = VISCA.parsePanTilt(reply)
        XCTAssertEqual(pt?.pan, -2)
        XCTAssertEqual(pt?.tilt, 0x0123)
    }

    func testParseZoom() {
        XCTAssertEqual(VISCA.parseZoom([0x90, 0x50, 0x04, 0x00, 0x00, 0x00, 0xFF]), 0x4000)
        XCTAssertNil(VISCA.parseZoom([0x90, 0x41, 0xFF]))
    }

    func testNibblesRoundTrip() {
        for v in [-32768, -1, 0, 1, 0x1234, 32767] {
            XCTAssertEqual(VISCA.signed16(VISCA.nibbles(v)[...]), v)
        }
    }
}

final class MotionMathTests: XCTestCase {
    func testTargetFollowsCurve() {
        let from = Pose(pan: 0, tilt: 0, zoom: 0)
        let to = Pose(pan: 1000, tilt: -200, zoom: 4000)
        let mid = MotionMath.target(from: from, to: to, duration: 4, easing: .gentle, progress: 0.5)
        XCTAssertEqual(mid.pose, Pose(pan: 500, tilt: -100, zoom: 2000))
        XCTAssertGreaterThan(mid.panVelocity, 0)
        XCTAssertLessThan(mid.tiltVelocity, 0)
    }

    func testCorrectionPushesTowardTarget() {
        var c = MotionCalibration()
        c.correctionGain = 1
        let cmd = MotionMath.command(target: Pose(pan: 100, tilt: 0, zoom: 0), panVelocity: 0, tiltVelocity: 0,
                                     zoomVelocity: 0, measured: Pose(pan: 0, tilt: 0, zoom: 0), calibration: c)
        XCTAssertGreaterThan(cmd.panStep, 0)
        XCTAssertEqual(cmd.tiltStep, 0)
    }

    func testStepsAreClamped() {
        let cmd = MotionMath.command(target: .home, panVelocity: 1e9, tiltVelocity: -1e9, zoomVelocity: 1e9,
                                     measured: nil, calibration: MotionCalibration())
        XCTAssertEqual(cmd, MotionMath.Command(panStep: 255, tiltStep: -255, zoomStep: 15))
    }
}

final class UpdateTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.2.0", than: "0.1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("nightly", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.2.3-beta", than: "1.2.2"))
    }

    func testDecodeRelease() throws {
        let json = #"{"tag_name":"v0.2.0","html_url":"https://github.com/o/r/releases/tag/v0.2.0","name":"0.2.0","body":"notes"}"#
        let r = try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
        XCTAssertEqual(r.version, "0.2.0")
        XCTAssertEqual(r.htmlURL.absoluteString, "https://github.com/o/r/releases/tag/v0.2.0")
    }
}

final class ControlServerTests: XCTestCase {
    func testRouteParsing() {
        XCTAssertEqual(ControlServer.route(fromRequest: "GET /scene/Sermon%20Close?x=1 HTTP/1.1\r\nHost: x\r\n\r\n"), ["scene", "Sermon Close"])
        XCTAssertEqual(ControlServer.route(fromRequest: "GET /stop HTTP/1.1\r\n\r\n"), ["stop"])
        XCTAssertNil(ControlServer.route(fromRequest: "DELETE /stop HTTP/1.1\r\n\r\n"))
        XCTAssertNil(ControlServer.route(fromRequest: ""))
    }
}

final class SilkTests: XCTestCase {
    func testSilkStartsAndEndsWithNoKick() {
        // Velocity and acceleration are ~0 at both ends.
        XCTAssertLessThan(abs(Easing.silk.slope(0)), 1e-3)
        XCTAssertLessThan(abs(Easing.silk.slope(1)), 1e-3)
        let h = 0.01
        let accelStart = (Easing.silk.slope(h) - Easing.silk.slope(0)) / h
        XCTAssertLessThan(abs(accelStart), 0.05)
    }

    func testSlewLimiterCapsChange() {
        var s = SlewLimiter(maxRatePerSecond: 100)
        XCTAssertEqual(s.step(toward: 255, dt: 0.05), 5, accuracy: 1e-9)
        XCTAssertEqual(s.step(toward: -255, dt: 0.05), 0, accuracy: 1e-9)
    }

    func testDithererAveragesFractionalSpeed() {
        var d = StepDitherer(limit: 255)
        let out = (0..<100).map { _ in d.next(1.3) }
        XCTAssertEqual(Double(out.reduce(0, +)) / 100, 1.3, accuracy: 0.02)
        XCTAssertTrue(out.allSatisfy { $0 == 1 || $0 == 2 })
        XCTAssertEqual(d.next(0), 0)
        XCTAssertEqual(d.next(-0.6), -1)
    }

    func testDithererHoldsSteadyAtCruiseSpeed() {
        var d = StepDitherer(limit: 255)
        let out = (0..<50).map { i in d.next(40.4 + 0.3 * sin(Double(i))) }
        XCTAssertEqual(Set(out).count, 1, "cruise speed should not flicker between steps: \(out)")
    }

    func testShaperNeverJumps() {
        var shaper = AxisShaper(calibration: MotionCalibration())
        var last = 0
        for _ in 0..<40 {
            let cmd = shaper.shape(MotionMath.Velocity(pan: 255, tilt: 0, zoom: 0), dt: 0.05)
            XCTAssertLessThanOrEqual(abs(cmd.panStep - last), 23) // 420 steps/s * 0.05 s, +1 for rounding
            last = cmd.panStep
        }
        XCTAssertEqual(last, 255)
    }

    func testCorrectionIgnoresTinyErrorsAndIsCapped() {
        let c = MotionCalibration()
        let tiny = MotionMath.velocity(target: Pose(pan: 3, tilt: 0, zoom: 0), panVelocity: 0, tiltVelocity: 0,
                                       zoomVelocity: 0, measured: .home, calibration: c)
        XCTAssertEqual(tiny.pan, 0)
        let huge = MotionMath.velocity(target: Pose(pan: 30000, tilt: 0, zoom: 0), panVelocity: 0, tiltVelocity: 0,
                                       zoomVelocity: 0, measured: .home, calibration: c)
        XCTAssertEqual(huge.pan, c.maxPanTiltCorrection / c.panUnitsPerSecondPerStep, accuracy: 1e-9)
    }

    func testMoveReachesEndPointOnSimulatedCamera() async {
        let cam = SimulatedCamera()
        var c = MotionCalibration()
        c.tickRate = 50
        c.latency = 0
        let engine = MoveEngine(camera: cam, calibration: c)
        let move = Move(id: "t", name: "t", end: Pose(pan: 400, tilt: -150, zoom: 0), duration: 3, easing: .silk)
        let outcome = await engine.perform(move)
        XCTAssertEqual(outcome, .arrived)
        XCTAssertTrue(MotionMath.isOnTarget(cam.pose, move.end), "\(cam.pose)")
        // No speed change bigger than the acceleration limit allows.
        let maxJump = zip(cam.glideSpeeds, cam.glideSpeeds.dropFirst()).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxJump, Int(c.panTiltAcceleration / c.tickRate) + 2)
    }
}

/// A camera that integrates speed commands using the default calibration.
final class SimulatedCamera: PTZCamera, @unchecked Sendable {
    private let lock = NSLock()
    /// How much faster the real camera moves than the calibration assumes (1 = exactly as calibrated).
    var speedScale = 1.0
    /// Extra factor for zoom alone, like a lens that runs faster than the calibration thinks.
    var zoomScale = 1.0
    /// Every Nth position read is "lost", like a dropped UDP reply.
    var dropEvery = 0
    private var reads = 0
    private var absoluteTarget: Pose?
    private var p = (pan: 0.0, tilt: 0.0, zoom: 0.0)
    private var v = (pan: 0, tilt: 0, zoom: 0)
    private var lastUpdate = Date()
    private(set) var glideSpeeds: [Int] = []
    let c = MotionCalibration()

    var pose: Pose {
        lock.lock(); defer { lock.unlock() }
        integrate()
        return Pose(pan: Int(p.pan.rounded()), tilt: Int(p.tilt.rounded()), zoom: Int(p.zoom.rounded()))
    }

    private func integrate() {
        let now = Date()
        let dt = now.timeIntervalSince(lastUpdate)
        lastUpdate = now
        if let t = absoluteTarget {
            let step = 3000 * dt
            func approach(_ x: Double, _ to: Int) -> Double {
                let d = Double(to) - x
                return abs(d) <= step ? Double(to) : x + (d > 0 ? step : -step)
            }
            p = (approach(p.pan, t.pan), approach(p.tilt, t.tilt), approach(p.zoom, t.zoom))
            return
        }
        p.pan += Double(v.pan) * c.panUnitsPerSecondPerStep * speedScale * dt
        p.tilt += Double(v.tilt) * c.tiltUnitsPerSecondPerStep * speedScale * dt
        p.zoom += Double(v.zoom) * c.zoomUnitsPerSecondPerStep * speedScale * zoomScale * dt
        p.tilt = max(p.tilt, tiltMin)
        p.zoom = max(p.zoom, zoomMin)
    }

    func readPose() async -> Pose? {
        lock.lock()
        reads += 1
        let drop = dropEvery > 0 && reads % dropEvery == 0
        lock.unlock()
        return drop ? nil : pose
    }

    func moveAbsolute(to pose: Pose, speed: Int) {
        lock.lock(); defer { lock.unlock() }
        integrate()
        v = (0, 0, 0)
        absoluteTarget = pose
    }

    func drive(panSpeed: Int, tiltSpeed: Int, zoomSpeed: Int) {
        lock.lock(); defer { lock.unlock() }
        integrate()
        absoluteTarget = nil
        v = (panSpeed, tiltSpeed, zoomSpeed)
        glideSpeeds.append(panSpeed)
    }

    func stopAll() {
        lock.lock(); defer { lock.unlock() }
        integrate()
        v = (0, 0, 0)
        absoluteTarget = nil
    }

    func setAutoFocus(_ on: Bool) {}
    func onePushFocus() {}
    private(set) var powerOn = true
    func setPower(_ on: Bool) { powerOn = on }
    func readPower() async -> Bool? { powerOn }
    /// Mechanical limits, like the real camera's end stops.
    var tiltMin = -1_000_000.0
    var zoomMin = 0.0
}

final class CoordinationTests: XCTestCase {
    func testAxisAheadIsHeldForTheSlowest() {
        let from = Pose(pan: 0, tilt: 0, zoom: 0), to = Pose(pan: 1000, tilt: 0, zoom: 8000)
        // Zoom is 60% of the way, pan only 20%: zoom must wait near 20%, pan keeps its plan.
        let r = MotionMath.coordinated(from: from, to: to, duration: 4, easing: .linear, progress: 0.5,
                                       measured: [0.2, nil, 0.6], lead: 0.05)
        XCTAssertTrue(r.held)
        XCTAssertEqual(r.pose.pan, 500)
        XCTAssertEqual(r.pose.zoom, 4800) // waits where it is (60%), never backs up
        XCTAssertEqual(r.zoomVelocity, 0)
        XCTAssertGreaterThan(r.panVelocity, 0)
    }

    /// Zoom runs twice as fast as calibrated: pan and zoom should still stay at about the same percentage.
    func testPanAndZoomMoveTogether() async {
        let cam = SimulatedCamera()
        cam.zoomScale = 2
        var c = MotionCalibration()
        c.tickRate = 50
        let engine = MoveEngine(camera: cam, calibration: c)
        let to = Pose(pan: 800, tilt: 0, zoom: 6000)
        let sampler = Task { () -> Double in
            var worst = 0.0
            while !Task.isCancelled {
                let q = cam.pose
                let fp = Double(q.pan) / 800, fz = Double(q.zoom) / 6000
                if fp > 0.1, fp < 0.9 { worst = max(worst, abs(fp - fz)) }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return worst
        }
        let outcome = await engine.perform(Move(id: "c", name: "c", end: to, duration: 2, easing: .linear))
        sampler.cancel()
        let worst = await sampler.value
        XCTAssertEqual(outcome, .arrived)
        XCTAssertLessThan(worst, 0.2, "pan and zoom drifted apart by \(worst)")
    }
}

final class LandingTests: XCTestCase {
    /// The calibration is a guess. Even when the camera is twice as fast as assumed, and some position
    /// replies are lost, a move must end exactly on the end point.
    func testLandsExactlyEvenWhenCalibrationIsWrong() async {
        let cam = SimulatedCamera()
        cam.speedScale = 2
        cam.dropEvery = 5
        var c = MotionCalibration()
        c.tickRate = 50
        let engine = MoveEngine(camera: cam, calibration: c)
        let move = Move(id: "t", name: "t", end: Pose(pan: -600, tilt: 220, zoom: 3000), duration: 1.5, easing: .silk)
        let outcome = await engine.perform(move)
        XCTAssertEqual(outcome, .arrived)
        XCTAssertTrue(MotionMath.isOnTarget(cam.pose, move.end), "\(cam.pose)")
        // And it learned that the camera is faster than assumed.
        XCTAssertGreaterThan(engine.calibration.panUnitsPerSecondPerStep, MotionCalibration().panUnitsPerSecondPerStep)
    }

    func testAlreadyThereJustLands() async {
        let cam = SimulatedCamera()
        let engine = MoveEngine(camera: cam)
        let outcome = await engine.moveTo(.home)
        XCTAssertEqual(outcome, .arrived)
        XCTAssertTrue(cam.glideSpeeds.allSatisfy { $0 == 0 })
    }

    func testLearnerIgnoresTinyMoves() {
        var l = CalibrationLearner(start: .home)
        l.commanded(MotionMath.Command(panStep: 1, tiltStep: 0, zoomStep: 0), dt: 0.05)
        l.observe(Pose(pan: 50, tilt: 0, zoom: 0))
        XCTAssertEqual(l.updated(MotionCalibration()), MotionCalibration())
    }
}

final class PowerTests: XCTestCase {
    func testPowerBytes() {
        XCTAssertEqual(VISCA.power(on: true), [0x81, 0x01, 0x04, 0x00, 0x02, 0xFF])
        XCTAssertEqual(VISCA.power(on: false), [0x81, 0x01, 0x04, 0x00, 0x03, 0xFF])
        XCTAssertEqual(VISCA.parsePower([0x90, 0x50, 0x02, 0xFF]), true)
        XCTAssertEqual(VISCA.parsePower([0x90, 0x50, 0x03, 0xFF]), false)
        XCTAssertNil(VISCA.parsePower([0x90, 0x50, 0x00, 0x00, 0xFF]))
    }

    func testParkTiltsFullyDownAndZoomsOut() async {
        let cam = SimulatedCamera()
        cam.tiltMin = -400
        cam.moveAbsolute(to: Pose(pan: 120, tilt: 50, zoom: 1500), speed: 24)
        try? await Task.sleep(nanoseconds: 700_000_000)
        let engine = MoveEngine(camera: cam)
        let end = await engine.park(timeout: 10)
        XCTAssertEqual(end?.tilt, -400)
        XCTAssertEqual(end?.zoom, 0)
        XCTAssertEqual(end?.pan, 120)
    }
}

final class TrackingTests: XCTestCase {
    private func person(x: Double, y: Double = 0.45) -> [Detection] {
        [Detection(box: CGRect(x: x - 0.1, y: y - 0.15, width: 0.2, height: 0.3), confidence: 0.9)]
    }

    func testCenteredSubjectDoesNotMoveCamera() {
        var t = TrackingController()
        t.observe(person(x: 0.52), at: 0)
        let cmd = t.command(at: 0, dt: 0.05, zoom: 0)
        XCTAssertEqual(cmd.panStep, 0)
        XCTAssertEqual(cmd.tiltStep, 0)
    }

    func testSubjectToTheRightPansRightAndRampsUp() {
        var t = TrackingController()
        var speeds: [Int] = []
        for i in 0..<20 {
            let time = Double(i) * 0.05
            t.observe(person(x: 0.8), at: time)
            speeds.append(t.command(at: time, dt: 0.05, zoom: 0).panStep)
        }
        XCTAssertGreaterThan(speeds.last!, 0)
        XCTAssertLessThanOrEqual(speeds.first!, 8, "should ease in, not jump")
        // Ramps up, then holds steady (dithering alternates between neighbouring steps for a fractional speed).
        XCTAssertEqual(Array(speeds.prefix(8)), Array(speeds.prefix(8)).sorted())
        let steady = speeds.suffix(10)
        XCTAssertLessThanOrEqual(steady.max()! - steady.min()!, 1)
    }

    func testLostSubjectEasesToStop() {
        var t = TrackingController()
        for i in 0..<30 {
            t.observe(person(x: 0.9), at: Double(i) * 0.05)
            _ = t.command(at: Double(i) * 0.05, dt: 0.05, zoom: 0)
        }
        var last = Int.max
        var time = 1.5
        for _ in 0..<60 {
            time += 0.05
            let s = t.command(at: time + 5, dt: 0.05, zoom: 0).panStep
            XCTAssertLessThanOrEqual(s, last)
            last = s
        }
        XCTAssertEqual(last, 0)
        XCTAssertTrue(t.isAtRest)
    }

    func testZoomedInMovesSlower() {
        XCTAssertEqual(TrackingController.zoomScale(0), 1, accuracy: 1e-9)
        XCTAssertEqual(TrackingController.zoomScale(0x4000), 0.2, accuracy: 1e-9)
    }

    func testSelectorSticksWithSamePerson() {
        var s = SubjectSelector()
        let pastor = Detection(box: CGRect(x: 0.4, y: 0.3, width: 0.15, height: 0.3), confidence: 0.9)
        _ = s.update([pastor], at: 0)
        // A bigger person walks in on the far left; keep following the pastor, who moved slightly.
        let moved = Detection(box: CGRect(x: 0.43, y: 0.3, width: 0.15, height: 0.3), confidence: 0.9)
        let other = Detection(box: CGRect(x: 0.0, y: 0.1, width: 0.3, height: 0.6), confidence: 0.95)
        let chosen = s.update([other, moved], at: 0.1)
        XCTAssertEqual(chosen, moved.box)
    }

    func testOneEuroSmoothsJitter() {
        var f = OneEuroFilter(minCutoff: 0.3, beta: 0.5)
        var outputs: [Double] = []
        for i in 0..<100 {
            outputs.append(f.filter(0.5 + (i % 2 == 0 ? 0.02 : -0.02), dt: 1.0 / 12))
        }
        let spread = outputs.suffix(20).max()! - outputs.suffix(20).min()!
        XCTAssertLessThan(spread, 0.02)
    }
}

final class NDITests: XCTestCase {
    func testFourCC() {
        XCTAssertEqual(NDILayout.fourCCBGRA, 0x4152_4742)
    }

    func testExtraIPsString() {
        XCTAssertEqual(NDILibrary.extraIPsString(["192.168.1.50", "10.0.0.9:5960, 192.168.1.50", " "]), "192.168.1.50,10.0.0.9")
        XCTAssertEqual(NDILibrary.extraIPsString(["", ""]), "")
    }

    func testMissingLibraryIsNil() {
        XCTAssertNil(NDILibrary.load(paths: ["/nonexistent/libndi.dylib"]))
    }

    func testPicksBirdDogByIP() {
        let sources = [
            NDISource(name: "PROCLAIM-PC (Proclaim)", address: "192.168.1.20:5961"),
            NDISource(name: "BIRDDOG-1A2B3 (CAM)", address: "192.168.1.50:5961"),
        ]
        XCTAssertEqual(NDISource.bestMatch(in: sources, cameraHost: "192.168.1.50")?.name, "BIRDDOG-1A2B3 (CAM)")
        XCTAssertEqual(NDISource.bestMatch(in: sources, cameraHost: "")?.name, "BIRDDOG-1A2B3 (CAM)")
    }
}

final class MoveDecodingTests: XCTestCase {
    func testOldSavedMovesStillLoad() throws {
        let json = #"[{"id":"a","name":"A","end":{"pan":1,"tilt":2,"zoom":3},"duration":4,"easing":"gentle"}]"#
        let moves = try JSONDecoder().decode([Move].self, from: Data(json.utf8))
        XCTAssertEqual(moves.first?.trackAfterArriving, false)
        XCTAssertEqual(moves.first?.easing, .gentle)
    }
}
