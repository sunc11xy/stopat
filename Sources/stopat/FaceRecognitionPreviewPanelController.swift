import AppKit
import AVFoundation
import SwiftUI

/// A local, transient diagnostics panel. It shows the existing camera session and face boxes;
/// it does not take photos, record video, or copy frames outside the preview layer.
@MainActor
final class FaceRecognitionPreviewPanelController {
    private var panel: NSPanel?

    func toggle(monitor: BackgroundMonitoringService, anchor: NSRect?) {
        guard panel?.isVisible != true else {
            panel?.orderOut(nil)
            return
        }
        show(monitor: monitor, anchor: anchor)
    }

    func show(monitor: BackgroundMonitoringService, anchor: NSRect? = nil) {
        if let panel {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }

        let content = FaceRecognitionPreview(monitor: monitor) { [weak self] in
            self?.panel?.orderOut(nil)
        }
        let host = NSHostingController(rootView: content)
        let size = NSSize(width: 380, height: 320)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        panel.contentViewController = host
        let target = frameBelowStatusItem(anchor: anchor, size: size)
        panel.setFrame(target.offsetBy(dx: 0, dy: 10), display: false)
        panel.alphaValue = 0
        self.panel = panel
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    private func frameBelowStatusItem(anchor: NSRect?, size: NSSize) -> NSRect {
        if let anchor {
            return NSRect(
                x: anchor.midX - size.width / 2,
                y: anchor.minY - size.height - 6,
                width: size.width,
                height: size.height
            )
        }
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 8, width: size.width, height: size.height)
    }
}

private struct FaceRecognitionPreview: View {
    @ObservedObject var monitor: BackgroundMonitoringService
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Local face detection")
                    .font(.headline)
                Spacer()
                Button("Close", action: dismiss)
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            CameraFacePreview(monitor: monitor)
                .frame(height: 235)

            Text("\(monitor.latestDetection?.faceCount ?? 0) detected • \(monitor.latestDetection?.screenFacingFaceCount ?? 0) facing screen")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
        }
        .frame(width: 380)
        .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .foregroundStyle(.white)
    }
}

private struct CameraFacePreview: NSViewRepresentable {
    @ObservedObject var monitor: BackgroundMonitoringService

    func makeNSView(context: Context) -> FacePreviewNSView {
        FacePreviewNSView(previewLayer: monitor.makePreviewLayer())
    }

    func updateNSView(_ preview: FacePreviewNSView, context: Context) {
        preview.update(detection: monitor.latestDetection)
    }
}

@MainActor
private final class FacePreviewNSView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private var boxLayers: [CAShapeLayer] = []
    private var detection: FaceDetection?

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
        renderBoxes()
    }

    func update(detection: FaceDetection?) {
        self.detection = detection
        renderBoxes()
    }

    private func renderBoxes() {
        boxLayers.forEach { $0.removeFromSuperlayer() }
        boxLayers.removeAll(keepingCapacity: true)
        guard let detection else { return }

        for face in detection.faces {
            // Vision rectangles use a lower-left origin; AVCapture metadata rectangles use a
            // top-left origin. Flip Y only. The preview connection handles its own mirroring,
            // so flipping X here would put the box on the opposite side of the face.
            let visionBox = face.boundingBox
            let metadataBox = CGRect(
                x: visionBox.minX,
                y: 1 - visionBox.maxY,
                width: visionBox.width,
                height: visionBox.height
            )
            let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataBox)
            let box = CAShapeLayer()
            box.path = CGPath(rect: rect, transform: nil)
            box.fillColor = NSColor.clear.cgColor
            box.strokeColor = (face.isFacingScreen ? NSColor.systemGreen : NSColor.systemGray).cgColor
            box.lineWidth = 2
            layer?.addSublayer(box)
            boxLayers.append(box)
        }
    }
}
