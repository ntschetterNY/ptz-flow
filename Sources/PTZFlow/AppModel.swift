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
    static let githubOwner = "ntschetterNY"
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

    // AI tracking
    @Published private(set) var trackingEnabled = false
    @Published var trackingSettings: TrackingSettings {
        didSet {
            tracker.settings = trackingSettings
            if let data = try? JSONEncoder().encode(trackingSettings) { UserDefaults.standard.set(data, forKey: "trackingSettings") }
        }
    }
    @Published private(set) var trackedBox: CGRect?
    let video = VideoPipeline()
    private var tracker: TrackingController
    private var trackingTask: Task<Void, Never>?
    private var stoppingTracking = false
    private var lastZoom: Int?

    let updateChecker = UpdateChecker(owner: AppModel.githubOwner, repo: AppModel.githubRepo)
    private let store = MoveStore()
    private var camera: BirdDogCamera?
    private var engine: MoveEngine?
    private var moveTask: Task<Void, Never>?
    private var server: ControlServer?
    private var updateTimer: Timer?

    init() {
        moves = store.load()
        let settings = UserDefaults.standard.data(forKey: "trackingSettings")
            .flatMap { try? JSONDecoder().decode(TrackingSettings.self, from: $0) } ?? TrackingSettings()
        trackingSettings = settings
        tracker = TrackingController(settings: settings)
        selectedMoveID = moves.first?.id
        video.onDetections = { [weak self] found in self?.observe(found) }
        video.findAndConnect(cameraHost: cameraHost)
        loadThumbnails()
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
        let engine = MoveEngine(camera: cam, calibration: Self.loadCalibration())
        engine.onCalibrationLearned = { c in
            if let data = try? JSONEncoder().encode(c) { UserDefaults.standard.set(data, forKey: "motionCalibration") }
        }
        self.engine = engine
        Task {
            let pose = await cam.readPose()
            connected = pose != nil
            addLog(pose != nil ? "Connected to camera at \(host)" : "No reply from \(host) on VISCA port 52381")
            lastZoom = pose?.zoom
        }
        if case .receiving = video.status {} else { video.findAndConnect(cameraHost: host) }
    }

    func run(moveID: String) {
        guard let move = moves.first(where: { $0.id == moveID }) else { return }
        play(move, label: move.name, runningID: move.id)
    }

    /// Recall preset 1...4 (the first four moves).
    func recallPreset(_ number: Int) {
        guard number >= 1, number <= moves.count, number <= 4 else { return }
        run(moveID: moves[number - 1].id)
    }

    /// The one path every move takes: Stream Deck, preset tiles, Play and Go all end up here.
    private func play(_ move: Move, label: String, runningID: String?) {
        guard let engine, let camera else {
            addLog("Can't move: camera not connected")
            return
        }
        moveTask?.cancel()
        runningMoveID = runningID
        progress = 0
        addLog("Going to “\(label)”")
        let focus = focusMode
        moveTask = Task { [weak self] in
            await self?.stopTracking(easeOut: true)
            if focus == .smoothAuto { camera.setAutoFocus(false) } // hold focus during the move
            let outcome = await engine.perform(move) { p in
                Task { @MainActor in self?.progress = p }
            }
            guard let self, !Task.isCancelled, outcome != .cancelled else { return }
            if self.runningMoveID == runningID { self.runningMoveID = nil }
            switch outcome {
            case .arrived:
                self.addLog("Arrived: \(label)")
            case .sentWithoutFeedback:
                self.addLog("Sent to “\(label)” (camera didn't report its position, so this wasn't checked)")
            case let .stoppedShort(at):
                self.addLog("“\(label)” stopped short at pan \(at.pan), tilt \(at.tilt), zoom \(at.zoom). Try Go again; if it repeats, re-save the end point.")
            case .cancelled:
                break
            }
            if move.trackAfterArriving { self.startTracking() }
            switch focus {
            case .smoothAuto:
                try? await Task.sleep(nanoseconds: 500_000_000)
                camera.setAutoFocus(true)
            case .onePush:
                camera.onePushFocus()
            case .manual:
                break
            }
            // Keep the preset's preview picture current (after focus has settled).
            if outcome == .arrived, let id = runningID, !move.trackAfterArriving {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self.saveThumbnail(for: id)
            }
        }
    }

    static func loadCalibration() -> MotionCalibration {
        UserDefaults.standard.data(forKey: "motionCalibration")
            .flatMap { try? JSONDecoder().decode(MotionCalibration.self, from: $0) } ?? MotionCalibration()
    }

    func stop() {
        Task { await stopTracking(easeOut: false) }
        moveTask?.cancel()
        moveTask = nil
        runningMoveID = nil
        camera?.stopAll()
        addLog("Held position")
    }

    /// Joystick input, -1...1 on each axis, with a response curve so small pushes creep.
    func jog(x: Double, y: Double, zoom: Double = 0) {
        guard let camera else { return }
        if runningMoveID != nil || trackingEnabled { stop() } // the operator takes over
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

    // MARK: Moves

    enum Point { case start, end }

    /// Moves the camera to a move's end point (or its optional start point), the same way a preset does.
    func goTo(_ point: Point, of moveID: String) {
        guard let move = moves.first(where: { $0.id == moveID }) else { return }
        if point == .end {
            var plain = move
            plain.start = nil               // "Go" means: straight to the end point
            plain.trackAfterArriving = false
            plain.duration = min(move.duration, 4)
            play(plain, label: move.name, runningID: move.id)
        } else if let start = move.start {
            let toStart = Move(id: move.id, name: move.name, end: start, duration: 2.5, easing: .silk)
            play(toStart, label: "\(move.name) start", runningID: nil)
        }
    }

    func clearStart(for moveID: String) {
        guard let i = moves.firstIndex(where: { $0.id == moveID }) else { return }
        moves[i].start = nil
        saveMoves()
        addLog("“\(moves[i].name)” now starts from wherever the camera is")
    }

    func addMove() {
        let move = Move.blank(named: "New move \(moves.count + 1)")
        moves.append(move)
        selectedMoveID = move.id
        saveMoves()
        if camera != nil { captureEnd(for: move.id) }
    }

    func deleteMove(_ moveID: String) {
        moves.removeAll { $0.id == moveID }
        thumbnails[moveID] = nil
        thumbnailStore.delete(for: moveID)
        if selectedMoveID == moveID { selectedMoveID = moves.first?.id }
        saveMoves()
    }

    /// Saves where the camera is now as the move's end point.
    func captureEnd(for moveID: String) {
        guard let camera else {
            addLog("Can't save the end point: camera not connected")
            return
        }
        Task {
            guard let i = moves.firstIndex(where: { $0.id == moveID }) else { return }
            guard let pose = await readPoseReliably(camera) else {
                addLog("Couldn't read the camera's position, so the end point for “\(moves[i].name)” was NOT saved. Try again.")
                return
            }
            moves[i].end = pose
            saveMoves()
            saveThumbnail(for: moveID)
            addLog("Saved end point for “\(moves[i].name)” (pan \(pose.pan), tilt \(pose.tilt), zoom \(pose.zoom))")
        }
    }

    private func readPoseReliably(_ camera: BirdDogCamera) async -> Pose? {
        for _ in 0..<5 {
            if let p = await camera.readPose() { return p }
        }
        return nil
    }

    // MARK: Preset pictures

    @Published private(set) var thumbnails: [String: CGImage] = [:]
    @Published var selectedMoveID: String?
    private let thumbnailStore = ThumbnailStore()

    private func saveThumbnail(for moveID: String) {
        guard let frame = video.frame, let small = ThumbnailStore.scaled(frame, width: 480) else { return }
        thumbnails[moveID] = small
        thumbnailStore.save(small, for: moveID)
    }

    func loadThumbnails() {
        for move in moves {
            if let image = thumbnailStore.load(for: move.id) { thumbnails[move.id] = image }
        }
    }

    func captureStart(for moveID: String) {
        guard let camera else { return }
        Task {
            guard let pose = await readPoseReliably(camera), let i = moves.firstIndex(where: { $0.id == moveID }) else {
                addLog("Couldn't read the camera's position; start point not saved")
                return
            }
            moves[i].start = pose
            saveMoves()
            addLog("Saved start point for “\(moves[i].name)”")
        }
    }

    func saveMoves() {
        do { try store.save(moves) } catch { addLog("Couldn't save moves: \(error.localizedDescription)") }
    }

    // MARK: Camera power

    /// What Turn On goes to once the camera is awake. Defaults to the pulpit close shot.
    @Published var turnOnMoveID: String? = UserDefaults.standard.string(forKey: "turnOnMoveID") {
        didSet { UserDefaults.standard.set(turnOnMoveID, forKey: "turnOnMoveID") }
    }
    /// Shown while Turn On / Turn Off is working, e.g. "Waking camera…".
    @Published private(set) var powerStatus: String?
    private var powerTask: Task<Void, Never>?

    /// The saved choice, or the move whose name mentions the pulpit (preferring a "close" one).
    var resolvedTurnOnMove: Move? {
        if let id = turnOnMoveID, let m = moves.first(where: { $0.id == id }) { return m }
        let pulpit = moves.filter { $0.name.localizedCaseInsensitiveContains("pulpit") }
        return pulpit.first { $0.name.localizedCaseInsensitiveContains("close") } ?? pulpit.first
    }

    /// Wakes the camera, waits until it has finished starting up, then glides to the Turn On shot.
    func turnOn() {
        if camera == nil { connect() }
        guard let camera else {
            addLog("Can't turn on: enter the camera's IP address first")
            return
        }
        powerTask?.cancel()
        powerStatus = "Waking camera…"
        addLog("Turn On: sending power on")
        camera.setPower(true)
        let target = resolvedTurnOnMove
        powerTask = Task { [weak self] in
            // A camera coming out of standby takes a while and may run its own start-up pan/tilt check.
            let deadline = Date().addingTimeInterval(120)
            var ready = false
            var lastPose: Pose?
            var stableFor = 0
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard await camera.readPower() == true, let pose = await camera.readPose() else {
                    camera.setPower(true) // in case the first command arrived while it was still booting
                    continue
                }
                stableFor = (pose == lastPose) ? stableFor + 1 : 0
                lastPose = pose
                if stableFor >= 2 { ready = true; break } // stopped moving for 2 s: start-up is done
                await MainActor.run { self?.powerStatus = "Camera starting up…" }
            }
            guard let self, !Task.isCancelled else { return }
            self.connected = ready
            guard ready else {
                self.powerStatus = nil
                self.addLog("Turn On: the camera didn't report ready within 2 minutes")
                return
            }
            self.addLog("Camera is on")
            self.powerStatus = nil
            if let target {
                self.run(moveID: target.id)
            } else {
                self.addLog("Turn On: no Turn On shot chosen, so the camera stays where it started")
            }
            if self.video.frame == nil { self.video.findAndConnect(cameraHost: self.cameraHost) }
        }
    }

    /// Parks the camera (lens all the way down, zoomed all the way out, to keep dust off), then powers it off.
    func turnOff() {
        guard let camera, let engine else {
            addLog("Can't turn off: camera not connected")
            return
        }
        powerTask?.cancel()
        moveTask?.cancel()
        runningMoveID = nil
        powerStatus = "Parking camera…"
        addLog("Turn Off: tilting down and zooming out")
        powerTask = Task { [weak self] in
            await self?.stopTracking(easeOut: false)
            let parked = await engine.park()
            guard let self, !Task.isCancelled else { return }
            if let parked { self.addLog("Parked at tilt \(parked.tilt), zoom \(parked.zoom)") }
            camera.setPower(false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let on = await camera.readPower()
            self.powerStatus = nil
            self.connected = false
            self.addLog(on == false ? "Camera is off (standby)" : "Sent power off")
        }
    }

    // MARK: AI tracking

    func setTracking(_ on: Bool) {
        if on { startTracking() } else { Task { await stopTracking(easeOut: true) } }
    }

    func startTracking() {
        guard let camera else {
            addLog("Can't track: camera not connected")
            return
        }
        guard case .receiving = video.status else {
            addLog("Can't track: no NDI preview (tracking needs the video)")
            return
        }
        if runningMoveID != nil {
            moveTask?.cancel()
            runningMoveID = nil
        }
        trackingTask?.cancel()
        tracker.reset()
        stoppingTracking = false
        trackingEnabled = true
        video.analyse = true
        if focusMode == .smoothAuto { camera.setAutoFocus(true) }
        addLog("AI tracking on")
        trackingTask = Task { [weak self] in
            let interval = 1.0 / 20
            var tick = 0
            let started = Date()
            while !Task.isCancelled {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                // While stopping, pretend the subject is gone so speed eases down to zero.
                let cmd = self.tracker.command(at: self.stoppingTracking ? .greatestFiniteMagnitude : now,
                                               dt: interval, zoom: self.lastZoom)
                camera.drive(panSpeed: cmd.panStep, tiltSpeed: cmd.tiltStep, zoomSpeed: 0)
                self.trackedBox = self.stoppingTracking ? nil : self.tracker.subject
                if self.stoppingTracking && self.tracker.isAtRest { break }
                tick += 1
                if tick % 20 == 0 { // refresh zoom about once a second, for zoom-aware speed
                    Task { if let z = await camera.readPose()?.zoom { self.lastZoom = z } }
                }
                let wait = started.addingTimeInterval(Double(tick) * interval).timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            camera.stopAll()
        }
    }

    /// Stops following. With `easeOut`, the camera glides to a stop instead of halting.
    func stopTracking(easeOut: Bool) async {
        guard trackingEnabled || trackingTask != nil else { return }
        trackingEnabled = false
        video.analyse = false
        trackedBox = nil
        if easeOut, let task = trackingTask {
            stoppingTracking = true
            await task.value
        } else {
            trackingTask?.cancel()
            camera?.stopAll()
        }
        trackingTask = nil
        stoppingTracking = false
        addLog("AI tracking off")
    }

    private func observe(_ detections: [Detection]) {
        guard trackingEnabled, !stoppingTracking else { return }
        tracker.observe(detections, at: ProcessInfo.processInfo.systemUptime)
        trackedBox = tracker.subject
    }

    /// Click on a person in the preview to follow them instead (normalized point, origin top-left).
    func chooseSubject(at point: CGPoint) {
        tracker.choose(near: point, from: video.detections, at: ProcessInfo.processInfo.systemUptime)
        trackedBox = tracker.subject
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
        case ("power", 2):
            switch route[1].lowercased() {
            case "on": turnOn()
            case "off": turnOff()
            default: return (404, #"{"error":"use /power/on or /power/off"}"#)
            }
            return (200, #"{"ok":true}"#)
        case ("preset", 2):
            guard let n = Int(route[1]), n >= 1, n <= min(4, moves.count) else { return (404, #"{"error":"use /preset/1 to /preset/4"}"#) }
            recallPreset(n)
            return (200, #"{"ok":true}"#)
        case ("move", 2):
            guard moves.contains(where: { $0.id == route[1] }) else { return (404, #"{"error":"unknown move"}"#) }
            run(moveID: route[1])
            return (200, #"{"ok":true}"#)
        case ("track", 2):
            switch route[1].lowercased() {
            case "on": startTracking()
            case "off": setTracking(false)
            case "toggle": setTracking(!trackingEnabled)
            default: return (404, #"{"error":"use /track/on, /track/off or /track/toggle"}"#)
            }
            return (200, "{\"tracking\":\(trackingEnabled)}")
        case ("stop", 1):
            stop()
            return (200, #"{"ok":true}"#)
        case ("status", 1):
            return (200, "{\"connected\":\(connected),\"running\":\(runningMoveID.map { "\"\($0)\"" } ?? "null"),\"tracking\":\(trackingEnabled),\"version\":\"\(AppVersion.running)\"}")
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
