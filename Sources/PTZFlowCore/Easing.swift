import Foundation

/// Easing curves for programmed camera moves. `value(t)` maps progress 0...1 to position 0...1.
public enum Easing: String, Codable, CaseIterable, Sendable {
    case linear
    case easeInOut
    case gentle
    case drift
    case silk

    public var label: String {
        switch self {
        case .linear: return "Linear"
        case .easeInOut: return "Ease in-out"
        case .gentle: return "Gentle S-curve"
        case .drift: return "Slow drift"
        case .silk: return "Silk"
        }
    }

    public func value(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        switch self {
        case .linear:
            return t
        case .easeInOut: // cubic
            return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .gentle: // smootherstep: zero velocity and acceleration at both ends
            return t * t * t * (t * (t * 6 - 15) + 10)
        case .drift: // sine
            return -(cos(Double.pi * t) - 1) / 2
        case .silk: // 7th-order: zero velocity, acceleration and jerk at both ends, so no "kick" leaving or arriving
            let t4 = t * t * t * t
            return t4 * (35 + t * (-84 + t * (70 - 20 * t)))
        }
    }

    /// d(value)/dt, used as the velocity feed-forward for a move.
    public func slope(_ t: Double) -> Double {
        let h = 1e-4
        let a = max(t - h, 0), b = min(t + h, 1)
        guard b > a else { return 0 }
        return (value(b) - value(a)) / (b - a)
    }
}
