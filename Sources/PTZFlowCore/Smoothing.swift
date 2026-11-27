import Foundation

/// Limits how fast a commanded speed may change from one tick to the next.
/// This is what stops a correction or a tracking nudge from showing up on air as a "kick".
public struct SlewLimiter: Equatable, Sendable {
    /// Largest change allowed per second, in the same units as the value (speed steps).
    public var maxRatePerSecond: Double
    public private(set) var value: Double = 0

    public init(maxRatePerSecond: Double, value: Double = 0) {
        self.maxRatePerSecond = maxRatePerSecond
        self.value = value
    }

    @discardableResult
    public mutating func step(toward target: Double, dt: Double) -> Double {
        guard target.isFinite, dt > 0 else { return value }
        let maxDelta = maxRatePerSecond * dt
        value += min(max(target - value, -maxDelta), maxDelta)
        return value
    }

    public mutating func reset(_ v: Double = 0) { value = v }
}

/// The "1€ filter" (Casiez et al., CHI 2012): smooths a noisy signal heavily while it is still,
/// and lets it through quickly when it really moves. Used on AI-tracking detections so a jittery
/// bounding box doesn't make the camera twitch, but a pastor walking across the stage is still followed.
public struct OneEuroFilter: Sendable {
    /// Lower = smoother when still (Hz).
    public var minCutoff: Double
    /// Higher = less lag when moving fast.
    public var beta: Double
    public var derivativeCutoff: Double = 1.0

    private var x: Double?
    private var dx: Double = 0

    public init(minCutoff: Double = 0.4, beta: Double = 0.8) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    public var current: Double? { x }

    public mutating func filter(_ value: Double, dt: Double) -> Double {
        guard let previous = x, dt > 0 else {
            x = value
            dx = 0
            return value
        }
        let rawDx = (value - previous) / dt
        dx += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (rawDx - dx)
        let cutoff = minCutoff + beta * abs(dx)
        let next = previous + Self.alpha(cutoff: cutoff, dt: dt) * (value - previous)
        x = next
        return next
    }

    public mutating func reset() {
        x = nil
        dx = 0
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Zero inside `width`, then rises from zero (no step at the edge of the dead zone).
public func softDeadzone(_ v: Double, width: Double) -> Double {
    let a = abs(v) - width
    return a <= 0 ? 0 : (v < 0 ? -a : a)
}
