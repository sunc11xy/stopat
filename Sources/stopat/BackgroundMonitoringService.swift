@preconcurrency import AVFoundation
import Combine
import Foundation

@MainActor
final class BackgroundMonitoringService: NSObject, ObservableObject {
    enum Sensitivity: Int, CaseIterable, Equatable {
        case light, medium, high

        var alertAfter: TimeInterval {
            switch self {
            case .light: 10
            case .medium: 5
            case .high: 0
            }
        }

        var blurAfterAlert: TimeInterval {
            switch self {
            case .light: 5
            case .medium: 3
            case .high: 0
            }
        }

        /// The visual transition is deliberately short, while still giving the user an
        /// understandable escalation at lower sensitivities.
        var blurTransitionDuration: TimeInterval {
            switch self {
            case .light: 1.0
            case .medium: 0.55
            case .high: 0.25
            }
        }
    }

    enum SecurityState: Equatable {
        case stopped
        case safe
        case warning(elapsed: TimeInterval)
        case alert

        var symbolName: String {
            switch self {
            case .stopped: "video.slash"
            case .safe: "eye.fill"
            case .warning: "eye.trianglebadge.exclamationmark.fill"
            case .alert: "exclamationmark.shield.fill"
            }
        }
    }

    struct Configuration: Equatable {
        /// Face rectangles do not identify people. One expected screen-facing face normally
        /// means the user. Faces turned away from the display do not count toward this value.
        var expectedScreenFacingFaceCount = 1
        var maximumFramesPerSecond: Double = 5
        /// Conservative head-pose gate. This estimates camera/screen orientation, not eye gaze.
        var maximumAbsoluteYawDegrees: Double = 25
    }

    @Published private(set) var state: SecurityState = .stopped
    @Published private(set) var latestDetection: FaceDetection?
    @Published private(set) var isMonitoring = false
    @Published private(set) var cameraPermissionGranted: Bool
    @Published private(set) var sensitivity: Sensitivity = .medium
    @Published private(set) var lastError: Error?

    let configuration: Configuration

    // These AVFoundation objects are owned exclusively by `sessionQueue`. They never cross back
    // to the main actor; published monitoring state remains main-actor isolated below.
    nonisolated(unsafe) private let session = AVCaptureSession()
    nonisolated private let sessionQueue = DispatchQueue(label: "com.stopat.capture.session", qos: .userInitiated)
    nonisolated private let captureQueue = DispatchQueue(label: "com.stopat.capture.frames", qos: .userInitiated)
    nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
    // The processor protects its own mutable scheduling state with a lock; marking this immutable
    // reference nonisolated lets AVCapture's nonisolated delegate submit frames without touching
    // any UI state.
    nonisolated private let visionProcessor: VisionProcessor
    private var unauthorizedSince: Date?
    nonisolated(unsafe) private var configured = false

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.cameraPermissionGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        self.visionProcessor = VisionProcessor(
            maximumFramesPerSecond: configuration.maximumFramesPerSecond,
            maximumAbsoluteYawDegrees: configuration.maximumAbsoluteYawDegrees
        )
        super.init()
    }

    func start() {
        guard !isMonitoring else { return }
        Task { [weak self] in
            guard let self else { return }
            guard await self.requestCameraAccessIfNeeded() else {
                self.lastError = MonitoringError.cameraAccessDenied
                return
            }
            self.cameraPermissionGranted = true
            self.configureAndStartSession()
        }
    }

    func stop() {
        isMonitoring = false
        unauthorizedSince = nil
        latestDetection = nil
        state = .stopped
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    /// Clears an alert without disabling the protection. A still-present onlooker will alert
    /// again only after another full threshold interval.
    func acknowledgeAlert() {
        guard case .alert = state else { return }
        unauthorizedSince = Date()
        state = .warning(elapsed: 0)
    }

    func setSensitivity(_ sensitivity: Sensitivity) {
        self.sensitivity = sensitivity
        // Apply a changed policy to an already-continuous detection immediately. This lets High
        // become immediate and lets a lower setting withdraw an alert until its longer delay.
        guard let unauthorizedSince else { return }
        let elapsed = Date().timeIntervalSince(unauthorizedSince)
        state = elapsed >= sensitivity.alertAfter ? .alert : .warning(elapsed: elapsed)
    }

    /// The layer only presents the existing local camera session; it does not retain frames.
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.connection?.automaticallyAdjustsVideoMirroring = false
        layer.connection?.isVideoMirrored = true
        return layer
    }

    private func requestCameraAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    private func configureAndStartSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.configured { try self.configureSession() }
                self.session.startRunning()
                Task { @MainActor [weak self] in
                    self?.isMonitoring = true
                    self?.state = .safe
                }
            } catch {
                Task { @MainActor [weak self] in self?.lastError = error }
            }
        }
    }

    nonisolated private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .medium

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw MonitoringError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(videoOutput) else {
            throw MonitoringError.cannotConfigureSession
        }
        session.addInput(input)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
        session.addOutput(videoOutput)
        configured = true
    }

    private func consume(_ detection: FaceDetection) {
        guard isMonitoring else { return }
        latestDetection = detection
        // This is intentionally a conservative head-pose gate, not biometric identity or exact
        // eye tracking. An extra face must be oriented toward the camera/display to count.
        let unauthorized = detection.screenFacingFaceCount > configuration.expectedScreenFacingFaceCount
        guard unauthorized else {
            unauthorizedSince = nil
            state = .safe
            return
        }

        let now = Date()
        if unauthorizedSince == nil { unauthorizedSince = now }
        let elapsed = now.timeIntervalSince(unauthorizedSince ?? now)
        state = elapsed >= sensitivity.alertAfter ? .alert : .warning(elapsed: elapsed)
    }
}

extension BackgroundMonitoringService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        visionProcessor.process(sampleBuffer) { [weak self] detection in
            Task { @MainActor [weak self] in self?.consume(detection) }
        }
    }
}

extension BackgroundMonitoringService {
    enum MonitoringError: LocalizedError {
        case cameraAccessDenied, noCamera, cannotConfigureSession

        var errorDescription: String? {
            switch self {
            case .cameraAccessDenied: "Camera access is required to monitor for onlookers."
            case .noCamera: "No camera is available."
            case .cannotConfigureSession: "The camera session could not be configured."
            }
        }
    }
}
