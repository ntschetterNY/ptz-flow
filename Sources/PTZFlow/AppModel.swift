import Foundation
import PTZFlowCore
import SwiftUI

enum FocusMode: String, CaseIterable, Identifiable {
    case manual = "Manual"
    case smoothAuto = "Smooth auto"
    case onePush = "One-push"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {
    // Change these if the GitHub repository is renamed or moved.
    static let githubOwner = "ntschetterNYP"
    static let githubRepo = "ptz-flow"

    @Published var cameraHost: String = UserDefaults.standard.string(forKey: "cameraHost") ?? ""
    @Published private(set) var connected = false
    @Published var moves: [Move]
    @Published private(set) var runningMoveID: String?
    @Published private(set) var progress: Double = 0
    @Published var focusMode: FocusMode = .smoothAuto
    @Published var isRecording = false
    @Published private(set) var availableUpdate: ReleaseInfo?
    @Published var updateDismissed = false
    @Published private(set) var log: [String] = []
    @Published private(set) var serverError: String?

    let updateChecker = UpdateChecker(owner: AppModel.githubOwner, repo: AppModel.githubRepo)
    private let store = MoveStore()
    private var camera: BirdDogCamera?
    private var engine: MoveEngine?
    private var moveTask: Task<Void, Never>?
    private var server: ControlServer?
    private var updateTimer: Timer?

    init() {
        moves = store.load()
        startServer()
        if !cameraHost.isEmpty { connect() }
        Task { await checkForUpdates() }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            Task { await self?.checkForUpdates() }
        }
    }

    // MARK: Camera

    func connect() {
        let host = cameraHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        UserDefaults.standard.set(host, forKey: "cameraHost")
        let cam = BirdDogCamera(host: host)
        camera = cam
        engine = MoveEngine(camera: cam)
        Task {
            let pose = await cam.readPose()
            connected = pose != nil
            addLog(pose != nil ? "Connected to camera at \(host)" : "No reply from \(host) on VISCA port 52381")
        }
    }

    func run(moveID: String) {
        guard let move = moves.first(where: { $0.id == moveID }), let engine, let camera else {
            addLog("Can't run the move: camera not connected")
            return
        }
        moveTask?.cancel()
        runningMoveID = move.id
        progress = 0
        addLog("Running “\(move.name)”")
        let focus = focusMode
        if focus == .smoothAuto { camera.setAutoFocus(false) } // hold focus during the move
        moveTask = Task { [weak self] in
            await engine.perform(move) { p in
                Task { @MainActor in self?.progress = p }
            }
            guard let self, !Task.isCancelled else { return }
            self.runningMoveID = nil
            self.addLog("Arrived: \(move.name)")
            switch focus {
            case .smoothAuto:
                try? await Task.sleep(nanoseconds: 500_000_000)
                camera.setAutoFocus(true)
            case .onePush:
                camera.onePushFocus()
            case .manual:
                break
            }
        }
    }

    func stop() {
        moveTask?.cancel()
        moveTask = nil
        runningMoveID = nil
        camera?.stopAll()
        addLog("Held position")
    }

    /// Joystick input, -1...1 on each axis, with a response curve so small pushes creep.
    func jog(x: Double, y: Double, zoom: Double = 0) {
        guard let camera else { return }
        if runningMoveID != nil { stop() }
        func curve(_ v: Double, _ limit: Double) -> Int {
            let shaped = (v < 0 ? -1 : 1) * pow(abs(v), 2)
            return Int((shaped * limit).rounded())
        }
        camera.drive(panSpeed: curve(x, 180), tiltSpeed: curve(-y, 140), zoomSpeed: curve(zoom, 10))
    }

    func releaseJog() {
        camera?.stopAll()
    }

    func applyFocusMode() {
        switch focusMode {
        case .manual: camera?.setAutoFocus(false)
        case .smoothAuto: camera?.setAutoFocus(true)
        case .onePush:
            camera?.setAutoFocus(false)
            camera?.onePushFocus()
        }
    }

    /// Saves where the camera is now as the move's end point.
    func captureEnd(for moveID: String) {
        guard let camera else { return }
        Task {
            guard let pose = await camera.readPose(), let i = moves.firstIndex(where: { $0.id == moveID }) else { return }
            moves[i].end = pose
            saveMoves()
            addLog("Saved end point for “\(moves[i].name)”")
        }
    }

    func captureStart(for moveID: String) {
        guard let camera else { return }
        Task {
            guard let pose = await camera.readPose(), let i = moves.firstIndex(where: { $0.id == moveID }) else { return }
            moves[i].start = pose
            saveMoves()
            addLog("Saved start point for “\(moves[i].name)”")
        }
    }

    func saveMoves() {
        do { try store.save(moves) } catch { addLog("Couldn't save moves: \(error.localizedDescription)") }
    }

    // MARK: Ecamm + Stream Deck

    /// Switch Ecamm to `scene` and run the move mapped to it, at the same time.
    func trigger(scene: String) {
        if let err = EcammBridge.switchScene(named: scene) {
            addLog("Ecamm didn't switch to “\(scene)”: \(err)")
        } else {
            addLog("Ecamm scene → \(scene)")
        }
        if let move = moves.first(where: { $0.ecammScene?.caseInsensitiveCompare(scene) == .orderedSame }) {
            run(moveID: move.id)
        }
    }

    private func startServer() {
        let server = ControlServer { [weak self] route in
            await self?.handle(route: route) ?? (status: 404, body: #"{"error":"not ready"}"#)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            serverError = "Stream Deck link couldn't start on port \(ControlServer.defaultPort): \(error.localizedDescription)"
        }
    }

    private func handle(route: [String]) -> (status: Int, body: String) {
        switch (route.first, route.count) {
        case ("scene", 2):
            trigger(scene: route[1])
            return (200, #"{"ok":true}"#)
        case ("move", 2):
            guard moves.contains(where: { $0.id == route[1] }) else { return (404, #"{"error":"unknown move"}"#) }
            run(moveID: route[1])
            return (200, #"{"ok":true}"#)
        case ("stop", 1):
            stop()
            return (200, #"{"ok":true}"#)
        case ("status", 1):
            return (200, "{\"connected\":\(connected),\"running\":\(runningMoveID.map { "\"\($0)\"" } ?? "null"),\"version\":\"\(AppVersion.running)\"}")
        default:
            return (404, #"{"error":"unknown route"}"#)
        }
    }

    // MARK: Updates

    func checkForUpdates() async {
        if let release = await updateChecker.availableUpdate(currentVersion: AppVersion.running) {
            if release != availableUpdate { updateDismissed = false }
            availableUpdate = release
        }
    }

    /// Never nag during a recording.
    var showUpdateBanner: Bool {
        availableUpdate != nil && !updateDismissed && !isRecording
    }

    // MARK: Log

    func addLog(_ text: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log.insert("\(time)  \(text)", at: 0)
        if log.count > 50 { log.removeLast() }
    }
}
