import CoreGraphics
import Foundation

/// A person found in a video frame. `box` is normalized 0...1 with the origin at the TOP-left.
public struct Detection: Equatable, Sendable {
    public var box: CGRect
    public var confidence: Double

    public init(box: CGRect, confidence: Double) {
        self.box = box
        self.confidence = confidence
    }
}

/// How AI tracking frames and follows the subject. Everything here is adjustable in the app.
public struct TrackingSettings: Codable, Equatable, Sendable {
    /// Where the subject's box center should sit in the frame (0...1, origin top-left).
    /// Slightly above middle leaves head room for an upper-body box.
    public var framingX: Double = 0.5
    public var framingY: Double = 0.45
    /// The subject can wander this far (fraction of the frame) before the camera reacts at all.
    /// A pastor shifting weight at the pulpit shouldn't move the shot.
    public var deadzone: Double = 0.08
    /// 0 = calm, slow follow. 1 = keeps up with fast walking. Changes the filter and the gain together.
    public var responsiveness: Double = 0.4
    /// Speed caps (extended VISCA steps, 0...255).
    public var maxPanStep: Double = 90
    public var maxTiltStep: Double = 45
    /// How fast follow speed may change (steps per second). Lower = silkier starts and stops.
    public var acceleration: Double = 140
    /// Keep the last position this long if the subject is briefly hidden (seconds), then ease to a stop.
    public var lostHold: Double = 1.0
    /// Move slower when zoomed in, so the shot moves at the same apparent speed at any zoom.
    public var zoomAware: Bool = true

    public init() {}

    var minCutoff: Double { 0.15 + 0.85 * responsiveness }
    var beta: Double { 0.3 + 2.2 * responsiveness }
    /// Steps per unit of frame error (a subject one full frame-width off center).
    var gain: Double { 90 + 260 * responsiveness }
}

/// Picks one subject out of the detections and keeps following that same person, rather than jumping
/// to whoever is largest in each frame.
public struct SubjectSelector: Sendable {
    public private(set) var subject: CGRect?
    public private(set) var lastSeen: Double = -.infinity

    public init() {}

    public mutating func update(_ detections: [Detection], at time: Double) -> CGRect? {
        let candidates = detections.filter { $0.confidence >= 0.3 && $0.box.width > 0 && $0.box.height > 0 }
        if let previous = subject {
            // Same person: best overlap, or the nearest box within a quarter frame.
            let best = candidates.max { Self.match($0.box, previous) < Self.match($1.box, previous) }
            if let best, Self.match(best.box, previous) > 0 {
                subject = best.box
                lastSeen = time
            }
        } else if let first = candidates.max(by: { Self.startScore($0.box) < Self.startScore($1.box) }) {
            subject = first.box
            lastSeen = time
        }
        return subject
    }

    public mutating func reset() {
        subject = nil
        lastSeen = -.infinity
    }

    /// Lets the operator pick a different person (normalized point, origin top-left).
    public mutating func choose(near point: CGPoint, from detections: [Detection], at time: Double) {
        let hit = detections.min { Self.distance($0.box, point) < Self.distance($1.box, point) }
        if let hit {
            subject = hit.box
            lastSeen = time
        }
    }

    static func match(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        let overlap = i.isNull ? 0 : Double(i.width * i.height) / Double(a.width * a.height + b.width * b.height - i.width * i.height)
        let d = hypot(Double(a.midX - b.midX), Double(a.midY - b.midY))
        let near = max(0, 0.25 - d) // up to 0.25 for a very close center
        return overlap + near
    }

    /// For the first lock: prefer big (close to camera) and central.
    static func startScore(_ r: CGRect) -> Double {
        Double(r.height) - 0.5 * hypot(Double(r.midX) - 0.5, Double(r.midY) - 0.5)
    }

    static func distance(_ r: CGRect, _ p: CGPoint) -> Double {
        hypot(Double(r.midX - p.x), Double(r.midY - p.y))
    }
}

/// Turns the tracked subject's position into smooth pan/tilt speeds.
/// Detections → subject selection → 1€ filter → dead zone with hysteresis → zoom-aware gain → speed cap →
/// acceleration limit → dithered steps. The camera never gets a step change in speed.
public struct TrackingController: Sendable {
    public var settings: TrackingSettings {
        didSet { applySettings() }
    }
    public private(set) var selector = SubjectSelector()
    private var fx = OneEuroFilter()
    private var fy = OneEuroFilter()
    private var lastObservation: Double?
    private var pan: SlewLimiter
    private var tilt: SlewLimiter
    private var panSteps = StepDitherer(limit: 255)
    private var tiltSteps = StepDitherer(limit: 255)
    private var followingX = false
    private var followingY = false

    public init(settings: TrackingSettings = TrackingSettings()) {
        self.settings = settings
        pan = SlewLimiter(maxRatePerSecond: settings.acceleration)
        tilt = SlewLimiter(maxRatePerSecond: settings.acceleration)
        applySettings()
    }

    private mutating func applySettings() {
        fx.minCutoff = settings.minCutoff; fx.beta = settings.beta
        fy.minCutoff = settings.minCutoff; fy.beta = settings.beta
        pan.maxRatePerSecond = settings.acceleration
        tilt.maxRatePerSecond = settings.acceleration
    }

    /// The smoothed subject position (normalized, origin top-left), if there is one.
    public var smoothedCenter: CGPoint? {
        guard let x = fx.current, let y = fy.current else { return nil }
        return CGPoint(x: x, y: y)
    }

    public var subject: CGRect? { selector.subject }

    /// Feed in each analysed frame's detections.
    public mutating func observe(_ detections: [Detection], at time: Double) {
        let before = selector.lastSeen
        guard let box = selector.update(detections, at: time), selector.lastSeen != before else { return }
        let dt = lastObservation.map { time - $0 } ?? 0
        lastObservation = time
        _ = fx.filter(Double(box.midX), dt: dt)
        _ = fy.filter(Double(box.midY), dt: dt)
    }

    public mutating func choose(near point: CGPoint, from detections: [Detection], at time: Double) {
        selector.choose(near: point, from: detections, at: time)
        fx.reset(); fy.reset(); lastObservation = nil
        if let box = selector.subject {
            _ = fx.filter(Double(box.midX), dt: 0)
            _ = fy.filter(Double(box.midY), dt: 0)
            lastObservation = time
        }
    }

    /// The speed to send now. `zoom` is the camera's zoom position (0 = wide ... 0x4000 = tele), if known.
    public mutating func command(at time: Double, dt: Double, zoom: Int?) -> MotionMath.Command {
        var wantPan = 0.0, wantTilt = 0.0
        if let c = smoothedCenter, time - selector.lastSeen <= settings.lostHold {
            let ex = Double(c.x) - settings.framingX           // + = subject is right of where we want it → pan right
            let ey = settings.framingY - Double(c.y)           // + = subject is above → tilt up
            // Start following outside the dead zone; once moving, keep going until nearly centered.
            followingX = abs(ex) > settings.deadzone || (followingX && abs(ex) > settings.deadzone * 0.25)
            followingY = abs(ey) > settings.deadzone || (followingY && abs(ey) > settings.deadzone * 0.25)
            let zoomScale = settings.zoomAware ? Self.zoomScale(zoom) : 1
            if followingX { wantPan = softDeadzone(ex, width: settings.deadzone * 0.25) * settings.gain * zoomScale }
            if followingY { wantTilt = softDeadzone(ey, width: settings.deadzone * 0.25) * settings.gain * zoomScale }
            wantPan = min(max(wantPan, -settings.maxPanStep), settings.maxPanStep)
            wantTilt = min(max(wantTilt, -settings.maxTiltStep), settings.maxTiltStep)
        } else {
            followingX = false
            followingY = false
        }
        let p = pan.step(toward: wantPan, dt: dt)
        let t = tilt.step(toward: wantTilt, dt: dt)
        return MotionMath.Command(panStep: panSteps.next(p), tiltStep: tiltSteps.next(t), zoomStep: 0)
    }

    /// True when the controller has eased all the way to a stop.
    public var isAtRest: Bool { abs(pan.value) < 0.5 && abs(tilt.value) < 0.5 }

    public mutating func reset() {
        selector.reset()
        fx.reset(); fy.reset(); lastObservation = nil
        pan.reset(); tilt.reset(); panSteps.reset(); tiltSteps.reset()
        followingX = false; followingY = false
    }

    /// 1.0 at full wide, down to 0.2 at full tele (a 20x lens narrows the view about that much in speed terms).
    static func zoomScale(_ zoom: Int?) -> Double {
        guard let zoom else { return 1 }
        let z = min(max(Double(zoom) / 0x4000, 0), 1)
        return 1 - 0.8 * z
    }
}
