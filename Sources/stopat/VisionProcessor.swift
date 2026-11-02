import AVFoundation
import Vision

/// A non-biometric face result. `boundingBox` is Vision-normalized (origin at lower-left).
struct DetectedFace: Sendable, Equatable {
    let boundingBox: CGRect
    /// Vision's estimated head yaw in degrees; `nil` means pose was unavailable.
    let yawDegrees: Double?
    /// `true` only for a face oriented approximately toward the webcam/display.
    let isFacingScreen: Bool
}

/// A non-biometric result from one frame.
struct FaceDetection: Sendable, Equatable {
    let faces: [DetectedFace]
    let timestamp: CMTime

    var faceCount: Int { faces.count }
    var screenFacingFaceCount: Int { faces.count(where: \.isFacingScreen) }
}

/// Performs one face-rectangle request at a time, on a private serial queue.
///
/// It deliberately accepts the sample buffer rather than creating a CGImage. Vision can read
/// the camera's CVPixelBuffer directly, avoiding an expensive copy on every frame.
final class VisionProcessor: @unchecked Sendable {
    typealias Completion = @Sendable (FaceDetection) -> Void

    private let queue = DispatchQueue(label: "com.stopat.vision", qos: .userInitiated)
    private let lock = NSLock()
    private var isProcessing = false
    private var lastStart = CFAbsoluteTimeGetCurrent() - 1
    private let minimumInterval: TimeInterval
    private let maximumAbsoluteYawDegrees: Double

    init(maximumFramesPerSecond: Double = 5, maximumAbsoluteYawDegrees: Double = 25) {
        precondition(maximumFramesPerSecond > 0)
        precondition((0...90).contains(maximumAbsoluteYawDegrees))
        minimumInterval = 1 / maximumFramesPerSecond
        self.maximumAbsoluteYawDegrees = maximumAbsoluteYawDegrees
    }

    /// Safe to call from the AVCaptureVideoDataOutput delegate queue.
    /// Frames arriving while Vision is busy, or before the FPS interval elapses, are discarded.
    func process(_ sampleBuffer: CMSampleBuffer, completion: @escaping Completion) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        guard !isProcessing, now - lastStart >= minimumInterval else {
            lock.unlock()
            return
        }
        isProcessing = true
        lastStart = now
        lock.unlock()
        let maximumYaw = maximumAbsoluteYawDegrees

        // Capturing this Swift-imported Core Foundation object strongly keeps it alive until the
        // asynchronous block finishes. ARC performs the retain/release; explicit CFRetain and
        // CFRelease are unavailable (and unnecessary) in modern Swift.
        queue.async { [weak self] in
            defer {
                self?.finishProcessing()
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let faceRequest = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: .up,
                options: [:]
            )

            do {
                try handler.perform([faceRequest])

                // Face rectangles give the inexpensive candidate set. Landmarks refine those
                // observations with Vision's yaw estimate; this remains entirely on-device.
                let landmarkRequest = VNDetectFaceLandmarksRequest()
                landmarkRequest.inputFaceObservations = faceRequest.results
                try handler.perform([landmarkRequest])
                let faces = (landmarkRequest.results ?? []).map { observation in
                    let yawDegrees = observation.yaw.map { $0.doubleValue * 180 / .pi }
                    return DetectedFace(
                        boundingBox: observation.boundingBox,
                        yawDegrees: yawDegrees,
                        // A missing estimate is deliberately non-threatening. This prevents a
                        // partial, obscured, or side-facing face from becoming an alert.
                        isFacingScreen: yawDegrees.map { abs($0) <= maximumYaw } ?? false
                    )
                }
                completion(FaceDetection(
                    faces: faces,
                    timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                ))
            } catch {
                // Treat an individual Vision failure as a dropped frame. Do not surface camera
                // contents or error telemetry; the next permitted frame can recover naturally.
            }
        }
    }

    private func finishProcessing() {
        lock.lock()
        isProcessing = false
        lock.unlock()
    }
}
