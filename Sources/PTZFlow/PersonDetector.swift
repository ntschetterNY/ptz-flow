import CoreGraphics
import Foundation
import PTZFlowCore
import Vision

/// On-device person detection with Apple Vision. Nothing leaves the Mac.
/// Frames arrive faster than we need, so it analyses at most `maxRate` per second and skips frames while busy.
final class PersonDetector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ptzflow.vision", qos: .userInitiated)
    private let busy = NSLock()
    private var isBusy = false
    private var lastRun = Date.distantPast
    var maxRate: Double = 12
    /// Upper body only gives a steadier box for a speaker at a pulpit; full body is better for someone walking.
    var upperBodyOnly = true

    /// `completion` is called on a background queue with boxes normalized 0...1, origin top-left.
    func process(_ image: CGImage, completion: @escaping @Sendable ([Detection]) -> Void) {
        busy.lock()
        let now = Date()
        guard !isBusy, now.timeIntervalSince(lastRun) >= 1 / maxRate else {
            busy.unlock()
            return
        }
        isBusy = true
        lastRun = now
        busy.unlock()

        let upperBody = upperBodyOnly
        queue.async { [weak self] in
            defer {
                self?.busy.lock()
                self?.isBusy = false
                self?.busy.unlock()
            }
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = upperBody
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                completion([])
                return
            }
            let detections = (request.results ?? []).map { o -> Detection in
                let b = o.boundingBox // origin bottom-left
                return Detection(box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                                 confidence: Double(o.confidence))
            }
            completion(detections)
        }
    }
}
