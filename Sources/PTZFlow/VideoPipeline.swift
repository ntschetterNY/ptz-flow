import CoreGraphics
import Foundation
import PTZFlowCore

/// NDI preview + person detection. Owns the NDI receiver and the detector; reports to AppModel on the main actor.
@MainActor
final class VideoPipeline: ObservableObject {
    enum Status: Equatable {
        case notInstalled
        case searching
        case noSources
        case receiving(String)
        case failed(String)

        var text: String {
            switch self {
            case .notInstalled: return "NDI not installed. Install the free NDI SDK for Apple from ndi.video, then press Find."
            case .searching: return "Looking for NDI sources…"
            case .noSources: return "No NDI sources found. Over a VPN, NDI can't discover sources on its own: make sure the camera's IP is entered, and add any other NDI machines under Extra NDI addresses."
            case let .receiving(name): return "Preview: \(name)"
            case let .failed(why): return why
            }
        }
    }

    @Published private(set) var status: Status = .searching
    @Published private(set) var sources: [NDISource] = []
    @Published private(set) var frame: CGImage?
    @Published private(set) var detections: [Detection] = []
    /// NDI offers two streams: the camera's light proxy (Standard) or the full-quality stream (High).
    @Published var highQuality: Bool = UserDefaults.standard.bool(forKey: "ndiHighQuality") {
        didSet {
            UserDefaults.standard.set(highQuality, forKey: "ndiHighQuality")
            if let current = sources.first(where: { $0.name == selectedSourceName }) ?? currentSource { connect(to: current) }
        }
    }
    private var currentSource: NDISource?
    /// Other machines to ask directly for NDI sources (e.g. the Proclaim PC), comma separated.
    /// The camera's own IP is always asked, so a VPN connection works without this.
    @Published var extraIPs: String = UserDefaults.standard.string(forKey: "ndiExtraIPs") ?? "" {
        didSet { UserDefaults.standard.set(extraIPs, forKey: "ndiExtraIPs") }
    }

    /// Called with each analysed frame's detections (main actor).
    var onDetections: (([Detection]) -> Void)?
    /// Whether frames should be analysed at all (tracking on, or boxes shown).
    var analyse = false

    private var receiver: NDIReceiver?
    private let detector = PersonDetector()
    private var lastFrameShown = Date.distantPast

    var selectedSourceName: String {
        get { UserDefaults.standard.string(forKey: "ndiSource") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "ndiSource") }
    }

    /// Finds sources and connects to the saved one, or the BirdDog that matches the camera IP.
    func findAndConnect(cameraHost: String) {
        guard let library = NDILibrary.shared() else {
            status = .notInstalled
            return
        }
        status = .searching
        let ips = [cameraHost, extraIPs]
        Task.detached(priority: .userInitiated) {
            let found = library.findSources(timeout: 6, extraIPs: ips)
            await MainActor.run {
                self.sources = found
                let saved = found.first { $0.name == self.selectedSourceName }
                if let pick = saved ?? NDISource.bestMatch(in: found, cameraHost: cameraHost) {
                    self.connect(to: pick)
                } else {
                    self.status = found.isEmpty ? .noSources : .failed("Pick the camera's NDI source from the list.")
                }
            }
        }
    }

    func connect(to source: NDISource) {
        guard let library = NDILibrary.shared() else {
            status = .notInstalled
            return
        }
        receiver?.stop()
        receiver = nil
        guard let r = NDIReceiver(library: library, source: source, highQuality: highQuality) else {
            status = .failed("Couldn't open NDI source \(source.name)")
            return
        }
        selectedSourceName = source.name
        currentSource = source
        receiver = r
        status = .receiving(source.name)
        r.start { [weak self] image in
            Task { @MainActor in self?.handle(image) }
        }
    }

    func stop() {
        receiver?.stop()
        receiver = nil
    }

    private func handle(_ image: CGImage) {
        let now = Date()
        if now.timeIntervalSince(lastFrameShown) >= 1.0 / 30 {
            frame = image
            lastFrameShown = now
        }
        guard analyse else {
            if !detections.isEmpty { detections = [] }
            return
        }
        detector.process(image) { [weak self] found in
            Task { @MainActor in
                guard let self, self.analyse else { return }
                self.detections = found
                self.onDetections?(found)
            }
        }
    }
}
