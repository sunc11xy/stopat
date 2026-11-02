import SwiftUI
import Combine

@main
struct StopatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let monitor = BackgroundMonitoringService()
    private var menuBar: MenuBarController?
    private let facePreview = FaceRecognitionPreviewPanelController()
    private let screenBlur = ScreenBlurController()
    private var stateObserver: AnyCancellable?
    private var blurLockObserver: AnyCancellable?
    private var blurWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBar = MenuBarController(
            monitor: monitor,
            blurController: screenBlur,
            onToggleFacePreview: { [weak self] in
                guard let self else { return }
                self.facePreview.toggle(
                    monitor: self.monitor,
                    anchor: self.menuBar?.statusButtonScreenFrame()
                )
            }
        )
        stateObserver = monitor.$state
            .sink { [weak self] state in
            guard let self else { return }
            if case .alert = state { self.scheduleBlur() }
            else { self.cancelBlur() }
        }
        blurLockObserver = screenBlur.$isLocked
            .dropFirst()
            .sink { [weak self] locked in
                guard let self, !locked else { return }
                if case .alert = self.monitor.state { return }
                self.screenBlur.dismissIfUnlocked()
            }
        // The simplified menu intentionally has no Start/Stop item. Begin monitoring here so
        // macOS presents its camera-permission prompt on first launch and the live Secure/Warning
        // indicator is always driven by actual webcam observations.
        monitor.start()
    }

    private func scheduleBlur() {
        guard blurWorkItem == nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.blurWorkItem = nil
                guard case .alert = self.monitor.state else { return }
                self.screenBlur.present(transitionDuration: self.monitor.sensitivity.blurTransitionDuration)
            }
        }
        blurWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + monitor.sensitivity.blurAfterAlert, execute: workItem)
    }

    private func cancelBlur() {
        blurWorkItem?.cancel()
        blurWorkItem = nil
        screenBlur.dismissIfUnlocked()
    }
}

struct NotchAlertCard: View {
    @ObservedObject var monitor: BackgroundMonitoringService

    var body: some View {
        HStack {
            Image(systemName: "eye.trianglebadge.exclamationmark.fill")
            Text("Extra face detected")
            Spacer()
            Button("Acknowledge", action: monitor.acknowledgeAlert)
        }
        .font(.caption.weight(.medium))
        .padding(12)
        .frame(width: 320)
        .background(.black.opacity(0.94), in: Capsule())
        .foregroundStyle(.white)
        .shadow(radius: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shoulder surfer alert")
    }
}
