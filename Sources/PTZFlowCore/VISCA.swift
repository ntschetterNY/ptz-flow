import Foundation

/// VISCA-over-IP packet building and parsing.
///
/// Byte layouts follow BirdDog's published "X1 Series VISCA over IP commands"
/// (https://birddog.tv/x1-series-visca-over-ip-commands/): UDP port 52381, an 8-byte header
/// (2-byte payload type, 2-byte payload length, 4-byte sequence number), then the VISCA payload.
public enum VISCA {
    public static let defaultPort: UInt16 = 52381

    public enum PayloadType: UInt16 {
        case command = 0x0100
        case inquiry = 0x0110
        case reply = 0x0111
        case control = 0x0200
    }

    public static func packet(_ type: PayloadType, payload: [UInt8], sequence: UInt32) -> [UInt8] {
        let length = UInt16(payload.count)
        return [
            UInt8(type.rawValue >> 8), UInt8(type.rawValue & 0xFF),
            UInt8(length >> 8), UInt8(length & 0xFF),
            UInt8((sequence >> 24) & 0xFF), UInt8((sequence >> 16) & 0xFF),
            UInt8((sequence >> 8) & 0xFF), UInt8(sequence & 0xFF),
        ] + payload
    }

    /// Control packet that resets the camera's expected sequence number.
    public static let resetSequencePacket: [UInt8] = packet(.control, payload: [0x01], sequence: 0)

    // MARK: Pan / tilt

    public enum PanDirection: UInt8, Sendable { case left = 1, right = 2, stop = 3 }
    public enum TiltDirection: UInt8, Sendable { case up = 1, down = 2, stop = 3 }

    /// Standard drive. Speeds 1...24 (0x18).
    public static func panTiltDrive(panSpeed: Int, tiltSpeed: Int, pan: PanDirection, tilt: TiltDirection) -> [UInt8] {
        [0x81, 0x01, 0x06, 0x01, UInt8(clamp(panSpeed, 1, 24)), UInt8(clamp(tiltSpeed, 1, 24)), pan.rawValue, tilt.rawValue, 0xFF]
    }

    /// Extended linear-speed drive. Speeds 0...255, which gives far finer steps for slow, smooth moves.
    public static func panTiltDriveExtended(panSpeed: Int, tiltSpeed: Int, pan: PanDirection, tilt: TiltDirection) -> [UInt8] {
        let p = UInt8(clamp(panSpeed, 0, 255))
        let t = UInt8(clamp(tiltSpeed, 0, 255))
        return [0x81, 0x01, 0x06, 0x11, p >> 4, p & 0x0F, t >> 4, t & 0x0F, pan.rawValue, tilt.rawValue, 0xFF]
    }

    /// Absolute position. Pan speed 1...24, tilt speed 1...21 (0x15). The camera moves at its own profile,
    /// so this is used only for quick repositioning, never for on-air moves.
    public static func absolutePanTilt(pan: Int, tilt: Int, panSpeed: Int, tiltSpeed: Int) -> [UInt8] {
        [0x81, 0x01, 0x06, 0x02, UInt8(clamp(panSpeed, 1, 24)), UInt8(clamp(tiltSpeed, 1, 21))]
            + nibbles(pan) + nibbles(tilt) + [0xFF]
    }

    public static let panTiltStop: [UInt8] = panTiltDrive(panSpeed: 1, tiltSpeed: 1, pan: .stop, tilt: .stop)
    public static let panTiltPositionInquiry: [UInt8] = [0x81, 0x09, 0x06, 0x12, 0xFF]

    // MARK: Zoom

    /// Extended variable zoom: speed -15...15. Positive = tele, negative = wide, 0 = stop.
    public static func zoomVariableExtended(speed: Int) -> [UInt8] {
        let direction: UInt8 = speed > 0 ? 2 : (speed < 0 ? 3 : 0)
        return [0x81, 0x01, 0x04, 0x07, 0x0A, direction, UInt8(clamp(abs(speed), 0, 15)), 0xFF]
    }

    public static func zoomDirect(_ position: Int) -> [UInt8] {
        [0x81, 0x01, 0x04, 0x47] + nibbles(clamp(position, 0, 0x4000)) + [0xFF]
    }

    public static let zoomStop: [UInt8] = [0x81, 0x01, 0x04, 0x07, 0x00, 0xFF]
    public static let zoomPositionInquiry: [UInt8] = [0x81, 0x09, 0x04, 0x47, 0xFF]

    // MARK: Focus

    public static func focusMode(auto: Bool) -> [UInt8] { [0x81, 0x01, 0x04, 0x38, auto ? 0x02 : 0x03, 0xFF] }
    public static let onePushAutoFocus: [UInt8] = [0x81, 0x01, 0x04, 0x18, 0x01, 0xFF]
    public static let focusModeInquiry: [UInt8] = [0x81, 0x09, 0x04, 0x38, 0xFF]

    // MARK: Power

    /// `81 01 04 00 02 FF` on, `... 03 FF` standby. The network stays up in standby, so the camera can be woken.
    public static func power(on: Bool) -> [UInt8] { [0x81, 0x01, 0x04, 0x00, on ? 0x02 : 0x03, 0xFF] }
    public static let powerInquiry: [UInt8] = [0x81, 0x09, 0x04, 0x00, 0xFF]

    /// `90 50 02 FF` = on, `90 50 03 FF` = standby.
    public static func parsePower(_ payload: [UInt8]) -> Bool? {
        guard payload.count == 4, payload[1] == 0x50, payload[3] == 0xFF else { return nil }
        switch payload[2] {
        case 0x02: return true
        case 0x03: return false
        default: return nil
        }
    }

    // MARK: Presets (the camera's own, kept for comparison; recall has no speed control over VISCA)

    public static func presetRecall(_ index: Int) -> [UInt8] { [0x81, 0x01, 0x04, 0x3F, 0x02, UInt8(clamp(index, 0, 0x3F)), 0xFF] }
    public static func presetSet(_ index: Int) -> [UInt8] { [0x81, 0x01, 0x04, 0x3F, 0x01, UInt8(clamp(index, 0, 0x3F)), 0xFF] }

    // MARK: Parsing replies (payload only, header already removed)

    /// `90 50 0Y 0Y 0Y 0Y 0Z 0Z 0Z 0Z FF`
    public static func parsePanTilt(_ payload: [UInt8]) -> (pan: Int, tilt: Int)? {
        guard payload.count == 11, payload[1] == 0x50, payload[10] == 0xFF else { return nil }
        return (signed16(payload[2...5]), signed16(payload[6...9]))
    }

    /// `90 50 0p 0q 0r 0s FF`
    public static func parseZoom(_ payload: [UInt8]) -> Int? {
        guard payload.count == 7, payload[1] == 0x50, payload[6] == 0xFF else { return nil }
        return Int(unsigned16(payload[2...5]))
    }

    // MARK: Helpers

    /// A 16-bit value as four nibbles, most significant first: 0x1234 -> [01, 02, 03, 04].
    public static func nibbles(_ value: Int) -> [UInt8] {
        let v = UInt16(truncatingIfNeeded: value)
        return [UInt8((v >> 12) & 0x0F), UInt8((v >> 8) & 0x0F), UInt8((v >> 4) & 0x0F), UInt8(v & 0x0F)]
    }

    static func unsigned16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        bytes.reduce(UInt16(0)) { ($0 << 4) | UInt16($1 & 0x0F) }
    }

    static func signed16(_ bytes: ArraySlice<UInt8>) -> Int {
        Int(Int16(bitPattern: unsigned16(bytes)))
    }

    static func clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int { min(max(v, lo), hi) }
}
