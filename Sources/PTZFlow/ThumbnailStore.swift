import AppKit
import CoreGraphics
import Foundation

/// Preview pictures of each preset's end point, saved as JPEGs in
/// ~/Library/Application Support/PTZ Flow/Thumbnails/<move id>.jpg
struct ThumbnailStore {
    let folder: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("PTZ Flow/Thumbnails", isDirectory: true)
    }

    private func url(for id: String) -> URL {
        let safe = id.replacingOccurrences(of: "/", with: "_")
        return folder.appendingPathComponent("\(safe).jpg")
    }

    func save(_ image: CGImage, for id: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        try? data.write(to: url(for: id), options: .atomic)
    }

    func load(for id: String) -> CGImage? {
        guard let data = try? Data(contentsOf: url(for: id)), let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.cgImage
    }

    func delete(for id: String) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// A smaller copy, so a 1080p frame doesn't become a 1080p thumbnail.
    static func scaled(_ image: CGImage, width: Int) -> CGImage? {
        guard image.width > width else { return image }
        let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
