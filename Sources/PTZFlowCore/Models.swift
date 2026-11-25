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

    public init(id: String, name: String, ecammScene: String? = nil, start: Pose? = nil, end: Pose, duration: Double, easing: Easing) {
        self.id = id
        self.name = name
        self.ecammScene = ecammScene
        self.start = start
        self.end = end
        self.duration = duration
        self.easing = easing
    }

    /// Placeholder moves. Their poses are zero until captured from the real camera.
    public static let defaults: [Move] = [
        Move(id: "wide", name: "Full stage wide", ecammScene: "Walk-in", end: .home, duration: 4, easing: .easeInOut),
        Move(id: "worship", name: "Worship leader", ecammScene: "Worship", end: .home, duration: 3.5, easing: .gentle),
        Move(id: "pulpit", name: "Pastor at pulpit", ecammScene: "Sermon", end: .home, duration: 3.5, easing: .gentle),
        Move(id: "prayer", name: "Prayer slow push-in", ecammScene: "Prayer", start: .home, end: .home, duration: 18, easing: .drift),
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
