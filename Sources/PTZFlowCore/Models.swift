import Foundation

/// A camera position in the camera's own VISCA units.
/// Pan and tilt are signed 16-bit values, zoom is 0 (wide) ... 0x4000 (tele) on BirdDog X1-series.
public struct Pose: Codable, Equatable, Sendable {
    public var pan: Int
    public var tilt: Int
    public var zoom: Int

    public init(pan: Int, tilt: Int, zoom: Int) {
        self.pan = pan
        self.tilt = tilt
        self.zoom = zoom
    }

    public static let home = Pose(pan: 0, tilt: 0, zoom: 0)

    public func interpolated(to other: Pose, fraction f: Double) -> Pose {
        Pose(
            pan: pan + Int((Double(other.pan - pan) * f).rounded()),
            tilt: tilt + Int((Double(other.tilt - tilt) * f).rounded()),
            zoom: zoom + Int((Double(other.zoom - zoom) * f).rounded())
        )
    }
}

/// A programmed move: optional start point, an end point, a duration and an easing curve.
public struct Move: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// The Ecamm scene that triggers this move, if any.
    public var ecammScene: String?
    /// If set, the camera first repositions here quickly, then plays the move.
    public var start: Pose?
    public var end: Pose
    /// Seconds.
    public var duration: Double
    public var easing: Easing
    /// Hand over to AI tracking once the camera arrives at the end point.
    public var trackAfterArriving: Bool

    public init(id: String, name: String, ecammScene: String? = nil, start: Pose? = nil, end: Pose, duration: Double,
                easing: Easing, trackAfterArriving: Bool = false) {
        self.id = id
        self.name = name
        self.ecammScene = ecammScene
        self.start = start
        self.end = end
        self.duration = duration
        self.easing = easing
        self.trackAfterArriving = trackAfterArriving
    }

    // Older saved moves don't have every field; fill in defaults instead of throwing the file away.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        ecammScene = try c.decodeIfPresent(String.self, forKey: .ecammScene)
        start = try c.decodeIfPresent(Pose.self, forKey: .start)
        end = try c.decode(Pose.self, forKey: .end)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 4
        easing = (try? c.decodeIfPresent(Easing.self, forKey: .easing)) ?? .silk
        trackAfterArriving = try c.decodeIfPresent(Bool.self, forKey: .trackAfterArriving) ?? false
    }

    /// A new, empty move, ready for its points to be captured.
    public static func blank(named name: String, end: Pose = .home) -> Move {
        Move(id: UUID().uuidString, name: name, ecammScene: nil, start: nil, end: end, duration: 5, easing: .silk)
    }

    /// Placeholder moves. Their poses are zero until captured from the real camera.
    public static let defaults: [Move] = [
        Move(id: "wide", name: "Full stage wide", ecammScene: "Walk-in", end: .home, duration: 4, easing: .easeInOut),
        Move(id: "worship", name: "Worship leader", ecammScene: "Worship", end: .home, duration: 3.5, easing: .silk),
        Move(id: "pulpit", name: "Pulpit close", ecammScene: "Sermon", end: .home, duration: 3.5, easing: .silk,
             trackAfterArriving: true),
        Move(id: "prayer", name: "Prayer slow push-in", ecammScene: "Prayer", end: .home, duration: 18, easing: .drift),
        Move(id: "baptism", name: "Baptism tank", ecammScene: "Baptism", end: .home, duration: 4.5, easing: .easeInOut),
    ]
}

/// Saves moves as JSON in ~/Library/Application Support/PTZ Flow/moves.json.
public struct MoveStore {
    public let url: URL

    public init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.url = base.appendingPathComponent("PTZ Flow", isDirectory: true).appendingPathComponent("moves.json")
        }
    }

    public func load() -> [Move] {
        guard let data = try? Data(contentsOf: url),
              let moves = try? JSONDecoder().decode([Move].self, from: data) else {
            return Move.defaults
        }
        return moves
    }

    public func save(_ moves: [Move]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(moves).write(to: url, options: .atomic)
    }
}
