import AppKit
import Combine
import SwiftUI

@MainActor
final class ScreenBlurController: ObservableObject {
    @Published private(set) var isLocked = false
    @Published private(set) var centerMessageEnabled = true
    @Published private(set) var centerMessage = "Screen protected"

    private var blurPanels: [NSPanel] = []
    private var lockPanel: NSPanel?
    private var overlayObservers: [NSObjectProtocol] = []

    init() {
        // A full-screen app has its own Space. Re-fronting the existing all-Spaces panels after
        // a Space change keeps the privacy layer and its lock slider above that app as well.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        overlayObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.restoreOverlayVisibility()
                }
            }
        )
        overlayObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.restoreOverlayVisibility()
                }
            }
        )
    }

    deinit {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in overlayObservers {
            workspaceCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func present(transitionDuration: TimeInterval) {
        guard blurPanels.isEmpty else { return }
        blurPanels = NSScreen.screens.map { makeBlurPanel(for: $0, transitionDuration: transitionDuration) }
        presentLockControl()
    }

    func dismissIfUnlocked() {
        guard !isLocked else { return }
        dismiss()
    }

    func lock() { isLocked = true }
    func unlock() { isLocked = false }
    func toggleCenterMessage() { centerMessageEnabled.toggle() }
    func setCenterMessage(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        centerMessage = trimmed.isEmpty ? "Screen protected" : trimmed
    }

    private func makeBlurPanel(for screen: NSScreen, transitionDuration: TimeInterval) -> NSPanel {
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false, screen: screen)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        effect.autoresizingMask = [.width, .height]
        effect.material = .fullScreenUI
        effect.blendingMode = .behindWindow
        effect.state = .active
        let message = NSHostingView(rootView: BlurMessageOverlay(controller: self))
        message.frame = effect.bounds
        message.autoresizingMask = [.width, .height]
        effect.addSubview(message)
        panel.contentView = effect
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = transitionDuration
            panel.animator().alphaValue = 1
        }
        return panel
    }

    private func presentLockControl() {
        guard lockPanel == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = NSSize(width: 190, height: 62)
        let host = NSHostingController(rootView: BlurLockControl(controller: self))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.contentViewController = host
        let visible = screen.visibleFrame
        panel.setFrame(NSRect(x: visible.maxX - size.width - 20, y: visible.minY + 20, width: size.width, height: size.height), display: false)
        panel.orderFrontRegardless()
        lockPanel = panel
    }

    private func dismiss() {
        let panels = blurPanels
        let control = lockPanel
        blurPanels.removeAll()
        lockPanel = nil
        (panels + [control].compactMap { $0 }).forEach { panel in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            } completionHandler: {
                panel.orderOut(nil)
            }
        }
    }

    private func restoreOverlayVisibility() {
        guard !blurPanels.isEmpty else { return }
        // Dispatching one run-loop turn later lets macOS finish moving to the destination Space
        // before these screen-saver-level panels are ordered above it.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.blurPanels.isEmpty else { return }
            self.blurPanels.forEach { $0.orderFrontRegardless() }
            self.lockPanel?.orderFrontRegardless()
        }
    }
}

private struct BlurMessageOverlay: View {
    @ObservedObject var controller: ScreenBlurController

    var body: some View {
        Group {
            if controller.centerMessageEnabled {
                Text(controller.centerMessage)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.9), radius: 12, x: 0, y: 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct BlurLockControl: View {
    @ObservedObject var controller: ScreenBlurController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(controller.isLocked ? "Slide left to unlock" : "Slide right to lock blur")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white)
            NativeLockSlider(controller: controller)
                .frame(width: 146)
                .frame(height: 24)
        }
        .padding(10)
        .frame(width: 190, height: 62)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

}

private struct NativeLockSlider: NSViewRepresentable {
    @ObservedObject var controller: ScreenBlurController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: controller.isLocked ? 1 : 0, minValue: 0, maxValue: 1, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        slider.numberOfTickMarks = 2
        slider.allowsTickMarkValuesOnly = true
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        slider.doubleValue = controller.isLocked ? 1 : 0
    }

    @MainActor
    final class Coordinator: NSObject {
        let controller: ScreenBlurController
        init(controller: ScreenBlurController) { self.controller = controller }
        @objc func changed(_ slider: NSSlider) {
            slider.doubleValue >= 0.5 ? controller.lock() : controller.unlock()
        }
    }
}
