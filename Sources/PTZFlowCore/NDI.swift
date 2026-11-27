import CoreGraphics
import Foundation

/// NDI video receive for the preview and AI tracking.
///
/// The NDI library is loaded at runtime with dlopen, so PTZ Flow builds and runs without the NDI SDK and simply
/// shows "NDI not installed" until it is. Install the free "NDI SDK for Apple" from ndi.video
/// (it puts libndi.dylib in /Library/NDI SDK for Apple/lib/macOS/).
///
/// Struct layouts below mirror Processing.NDI.structs.h / Processing.NDI.Recv.h for 64-bit macOS. They are
/// written out by hand (rather than imported from the SDK header) so the app doesn't need the SDK to build.
/// NDI® is a registered trademark of Vizrt NDI AB.
public enum NDILayout {
    // NDIlib_source_t { const char* p_ndi_name; const char* p_url_address; }
    public static let sourceSize = 16
    // NDIlib_find_create_t { bool show_local_sources; const char* p_groups; const char* p_extra_ips; }
    public static let findCreateSize = 24
    public static let findShowLocal = 0, findGroups = 8, findExtraIPs = 16
    // NDIlib_recv_create_v3_t { NDIlib_source_t source; int32 color_format; int32 bandwidth; bool allow_video_fields; const char* p_ndi_recv_name; }
    public static let recvCreateSize = 40
    public static let recvSourceName = 0, recvSourceURL = 8, recvColorFormat = 16, recvBandwidth = 20, recvAllowFields = 24, recvName = 32
    // NDIlib_video_frame_v2_t { int xres, yres; FourCC; int frame_rate_N, frame_rate_D; float aspect; int frame_format;
    //                            int64 timecode; uint8* p_data; int line_stride; const char* p_metadata; int64 timestamp; }
    public static let videoFrameSize = 72
    public static let videoXres = 0, videoYres = 4, videoFourCC = 8, videoData = 40, videoStride = 48

    public static let colorFormatBGRX_BGRA: Int32 = 0
    public static let bandwidthLowest: Int32 = 0
    public static let bandwidthHighest: Int32 = 100
    public static let frameTypeVideo: Int32 = 1

    public static func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * UInt32($1.offset))) }
    }
    public static let fourCCBGRA = fourCC("BGRA")
    public static let fourCCBGRX = fourCC("BGRX")
}

public struct NDISource: Hashable, Identifiable, Sendable {
    public var name: String
    public var address: String?
    public var id: String { name }

    public init(name: String, address: String?) {
        self.name = name
        self.address = address
    }

    /// The BirdDog's NDI source, matched by the camera's IP if it's in the address, else by name.
    public static func bestMatch(in sources: [NDISource], cameraHost: String) -> NDISource? {
        let host = cameraHost.trimmingCharacters(in: .whitespaces)
        if !host.isEmpty, let byIP = sources.first(where: { ($0.address ?? "").hasPrefix(host + ":") || $0.address == host }) {
            return byIP
        }
        return sources.first { $0.name.localizedCaseInsensitiveContains("birddog") } ?? (sources.count == 1 ? sources.first : nil)
    }
}

extension NDILibrary {
    /// "192.168.1.50, 10.0.0.9" → "192.168.1.50,10.0.0.9", dropping blanks, ports and duplicates.
    public static func extraIPsString(_ ips: [String]) -> String {
        var seen = Set<String>()
        var out: [String] = []
        let separators = CharacterSet(charactersIn: ", \n\t")
        for entry in ips {
            for piece in entry.components(separatedBy: separators) {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                let host = trimmed.components(separatedBy: ":").first ?? trimmed
                if !host.isEmpty, seen.insert(host).inserted {
                    out.append(host)
                }
            }
        }
        return out.joined(separator: ",")
    }

}

public final class NDILibrary: @unchecked Sendable {
    typealias InitializeFn = @convention(c) () -> Bool
    typealias FindCreateFn = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
    typealias FindWaitFn = @convention(c) (OpaquePointer?, UInt32) -> Bool
    typealias FindSourcesFn = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt32>?) -> UnsafeRawPointer?
    typealias DestroyFn = @convention(c) (OpaquePointer?) -> Void
    typealias RecvCreateFn = @convention(c) (UnsafeRawPointer?) -> OpaquePointer?
    typealias RecvCaptureFn = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> Int32
    typealias RecvFreeVideoFn = @convention(c) (OpaquePointer?, UnsafeRawPointer?) -> Void

    let path: String
    let findCreate: FindCreateFn
    let findWait: FindWaitFn
    let getSources: FindSourcesFn
    let findDestroy: DestroyFn
    let recvCreate: RecvCreateFn
    let recvDestroy: DestroyFn
    let recvCapture: RecvCaptureFn
    let recvFreeVideo: RecvFreeVideoFn

    /// Where to look for libndi.dylib, in order.
    public static var searchPaths: [String] {
        var paths: [String] = []
        let env = ProcessInfo.processInfo.environment
        for key in ["NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5"] {
            if let dir = env[key] { paths.append((dir as NSString).appendingPathComponent("libndi.dylib")) }
        }
        if let frameworks = Bundle.main.privateFrameworksPath {
            paths.append((frameworks as NSString).appendingPathComponent("libndi.dylib"))
        }
        paths += [
            "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib",
            "/usr/local/lib/libndi.dylib",
            "/opt/homebrew/lib/libndi.dylib",
        ]
        return paths
    }

    private static let lock = NSLock()
    private static var cached: NDILibrary?

    /// Loads the NDI runtime, or returns nil if it isn't installed.
    public static func shared() -> NDILibrary? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        cached = load(paths: searchPaths)
        return cached
    }

    static func load(paths: [String]) -> NDILibrary? {
        for path in paths where FileManager.default.fileExists(atPath: path) {
            if let lib = NDILibrary(path: path) { return lib }
        }
        return nil
    }

    private init?(path: String) {
        guard let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return nil }
        func sym<T>(_ name: String, _: T.Type) -> T? {
            guard let p = dlsym(h, name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        guard let initialize = sym("NDIlib_initialize", InitializeFn.self),
              let findCreate = sym("NDIlib_find_create_v2", FindCreateFn.self),
              let findWait = sym("NDIlib_find_wait_for_sources", FindWaitFn.self),
              let getSources = sym("NDIlib_find_get_current_sources", FindSourcesFn.self),
              let findDestroy = sym("NDIlib_find_destroy", DestroyFn.self),
              let recvCreate = sym("NDIlib_recv_create_v3", RecvCreateFn.self),
              let recvDestroy = sym("NDIlib_recv_destroy", DestroyFn.self),
              let recvCapture = sym("NDIlib_recv_capture_v2", RecvCaptureFn.self),
              let recvFreeVideo = sym("NDIlib_recv_free_video_v2", RecvFreeVideoFn.self),
              initialize() else {
            dlclose(h)
            return nil
        }
        self.path = path
        self.findCreate = findCreate
        self.findWait = findWait
        self.getSources = getSources
        self.findDestroy = findDestroy
        self.recvCreate = recvCreate
        self.recvDestroy = recvDestroy
        self.recvCapture = recvCapture
        self.recvFreeVideo = recvFreeVideo
    }

    /// Looks for NDI sources for up to `timeout` seconds. Call off the main thread.
    ///
    /// NDI normally finds sources with mDNS (Bonjour), which does not cross a VPN or a routed subnet.
    /// `extraIPs` are asked directly instead, so a camera reached over a VPN still shows up.
    public func findSources(timeout: TimeInterval = 3, extraIPs: [String] = []) -> [NDISource] {
        let settings = UnsafeMutableRawPointer.allocate(byteCount: NDILayout.findCreateSize, alignment: 8)
        let ips = Self.extraIPsString(extraIPs)
        let ipsC: UnsafeMutablePointer<CChar>? = ips.isEmpty ? nil : strdup(ips)
        defer {
            settings.deallocate()
            free(ipsC)
        }
        settings.initializeMemory(as: UInt8.self, repeating: 0, count: NDILayout.findCreateSize)
        settings.storeBytes(of: true, toByteOffset: NDILayout.findShowLocal, as: Bool.self)
        settings.storeBytes(of: ipsC.map { UnsafePointer($0) }, toByteOffset: NDILayout.findExtraIPs, as: UnsafePointer<CChar>?.self)
        guard let finder = findCreate(settings) else { return [] }
        defer { findDestroy(finder) }

        let deadline = Date().addingTimeInterval(timeout)
        var result: [NDISource] = []
        while Date() < deadline {
            let changed = findWait(finder, 1000)
            var count: UInt32 = 0
            if let list = getSources(finder, &count), count > 0 {
                result = (0..<Int(count)).compactMap { i in
                    let base = list + i * NDILayout.sourceSize
                    guard let name = base.load(fromByteOffset: 0, as: UnsafePointer<CChar>?.self) else { return nil }
                    let url = base.load(fromByteOffset: 8, as: UnsafePointer<CChar>?.self)
                    return NDISource(name: String(cString: name), address: url.map { String(cString: $0) })
                }
            }
            if !result.isEmpty && !changed { break } // list has settled
        }
        return result
    }
}

/// Receives one NDI source on a background thread and hands each video frame over as a CGImage.
public final class NDIReceiver: @unchecked Sendable {
    public let source: NDISource
    private let library: NDILibrary
    private let instance: OpaquePointer
    private let running = Locked(false)
    private var thread: Thread?

    /// `highQuality` = full-resolution stream. The default (false) asks the camera for its low-bandwidth
    /// proxy stream, which is plenty for a preview and for person detection, and is light on the network.
    public init?(library: NDILibrary, source: NDISource, highQuality: Bool = false) {
        self.library = library
        self.source = source
        let settings = UnsafeMutableRawPointer.allocate(byteCount: NDILayout.recvCreateSize, alignment: 8)
        settings.initializeMemory(as: UInt8.self, repeating: 0, count: NDILayout.recvCreateSize)
        let name = strdup(source.name)
        let url: UnsafeMutablePointer<CChar>? = source.address.flatMap { strdup($0) }
        let recvName = strdup("PTZ Flow preview")
        defer {
            free(name); free(url); free(recvName)
            settings.deallocate()
        }
        settings.storeBytes(of: UnsafePointer(name), toByteOffset: NDILayout.recvSourceName, as: UnsafePointer<CChar>?.self)
        settings.storeBytes(of: url.map { UnsafePointer($0) }, toByteOffset: NDILayout.recvSourceURL, as: UnsafePointer<CChar>?.self)
        settings.storeBytes(of: NDILayout.colorFormatBGRX_BGRA, toByteOffset: NDILayout.recvColorFormat, as: Int32.self)
        settings.storeBytes(of: highQuality ? NDILayout.bandwidthHighest : NDILayout.bandwidthLowest,
                            toByteOffset: NDILayout.recvBandwidth, as: Int32.self)
        settings.storeBytes(of: false, toByteOffset: NDILayout.recvAllowFields, as: Bool.self)
        settings.storeBytes(of: UnsafePointer(recvName), toByteOffset: NDILayout.recvName, as: UnsafePointer<CChar>?.self)
        guard let inst = library.recvCreate(settings) else { return nil }
        instance = inst
    }

    deinit {
        stop()
        library.recvDestroy(instance)
    }

    public func start(onFrame: @escaping @Sendable (CGImage) -> Void) {
        guard !running.value else { return }
        running.value = true
        let t = Thread { [weak self] in self?.captureLoop(onFrame) }
        t.name = "PTZ Flow NDI receive"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    public func stop() {
        running.value = false
    }

    private func captureLoop(_ onFrame: @Sendable (CGImage) -> Void) {
        let frame = UnsafeMutableRawPointer.allocate(byteCount: NDILayout.videoFrameSize, alignment: 8)
        defer { frame.deallocate() }
        while running.value {
            frame.initializeMemory(as: UInt8.self, repeating: 0, count: NDILayout.videoFrameSize)
            let type = library.recvCapture(instance, frame, nil, nil, 500)
            guard type == NDILayout.frameTypeVideo else { continue }
            let image = Self.makeImage(frame)
            library.recvFreeVideo(instance, frame)
            if let image { onFrame(image) }
        }
    }

    /// Copies a BGRA/BGRX NDI frame into a CGImage (alpha ignored).
    static func makeImage(_ frame: UnsafeMutableRawPointer) -> CGImage? {
        let width = Int(frame.load(fromByteOffset: NDILayout.videoXres, as: Int32.self))
        let height = Int(frame.load(fromByteOffset: NDILayout.videoYres, as: Int32.self))
        let fourCC = frame.load(fromByteOffset: NDILayout.videoFourCC, as: UInt32.self)
        let stride = Int(frame.load(fromByteOffset: NDILayout.videoStride, as: Int32.self))
        guard width > 0, height > 0, stride >= width * 4,
              fourCC == NDILayout.fourCCBGRA || fourCC == NDILayout.fourCCBGRX,
              let data = frame.load(fromByteOffset: NDILayout.videoData, as: UnsafeMutablePointer<UInt8>?.self),
              let provider = CGDataProvider(data: Data(bytes: data, count: stride * height) as CFData) else {
            return nil
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A tiny lock-protected value.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
