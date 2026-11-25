import XCTest
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
