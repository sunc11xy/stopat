import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject {
    enum Language: CaseIterable { case english, chinese, japanese, korean
        var title: String { switch self { case .english: "English"; case .chinese: "Chinese"; case .japanese: "Japanese"; case .korean: "Korean" } }
    }

    private let monitor: BackgroundMonitoringService
    private let blurController: ScreenBlurController
    private let onToggleFacePreview: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let sensitivityMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let showPreviewMenuItem = NSMenuItem(title: "", action: #selector(toggleFacePreview), keyEquivalent: "")
    private let showCenterMessageMenuItem = NSMenuItem(title: "Show Blur Message", action: #selector(toggleCenterMessage), keyEquivalent: "")
    private let customizeMessageMenuItem = NSMenuItem(title: "Customize Blur Message…", action: #selector(customizeCenterMessage), keyEquivalent: "")
    private let languageMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let quitMenuItem = NSMenuItem(title: "", action: #selector(quit), keyEquivalent: "q")
    private var languageItems: [Language: NSMenuItem] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var flashTimer: Timer?
    private var flashIsDimmed = false
    private var renderedState: BackgroundMonitoringService.SecurityState = .stopped
    private var language: Language = .english
    private var sensitivitySlider: NSSlider?
    private var sensitivityTitleLabel: NSTextField?
    private var sensitivityLevelLabels: [NSTextField] = []
    private var highSensitivityGlow: HighSensitivityGlowView?
    private var highSensitivityBadge: NSTextField?

    init(
        monitor: BackgroundMonitoringService,
        blurController: ScreenBlurController,
        onToggleFacePreview: @escaping () -> Void
    ) {
        self.monitor = monitor
        self.blurController = blurController
        self.onToggleFacePreview = onToggleFacePreview
        super.init()
        configureMenu()
        monitor.$state.sink { [weak self] state in self?.render(state) }.store(in: &subscriptions)
        monitor.$latestDetection
            .sink { [weak self] _ in self?.render(self?.monitor.state ?? .stopped) }
            .store(in: &subscriptions)
        monitor.$cameraPermissionGranted
            .sink { [weak self] granted in self?.updatePreviewAvailability(granted: granted) }
            .store(in: &subscriptions)
        monitor.$sensitivity
            .sink { [weak self] value in
                self?.sensitivitySlider?.integerValue = value.rawValue
                self?.setSensitivityEffect(for: value)
            }
            .store(in: &subscriptions)
        blurController.$centerMessageEnabled
            .sink { [weak self] enabled in self?.showCenterMessageMenuItem.state = enabled ? .on : .off }
            .store(in: &subscriptions)
    }

    private func configureMenu() {
        statusMenuItem.isEnabled = false
        showPreviewMenuItem.target = self
        showCenterMessageMenuItem.target = self
        customizeMessageMenuItem.target = self
        quitMenuItem.target = self
        sensitivityMenuItem.view = sensitivityView()
        sensitivityMenuItem.isEnabled = true

        let languages = NSMenu(title: "Language")
        for option in Language.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.title
            languages.addItem(item)
            languageItems[option] = item
        }
        languageMenuItem.submenu = languages

        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(sensitivityMenuItem)
        menu.addItem(showPreviewMenuItem)
        menu.addItem(showCenterMessageMenuItem)
        menu.addItem(customizeMessageMenuItem)
        menu.addItem(languageMenuItem)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem)
        statusItem.menu = menu
        applyLanguage()
    }

    /// A fixed-size menu control. NSMenu can collapse an unconstrained stack view to zero height.
    private func sensitivityView() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 244, height: 62))
        let glow = HighSensitivityGlowView(frame: NSRect(x: 10, y: 20, width: 224, height: 22))
        glow.isHidden = true
        let title = NSTextField(labelWithString: "Sensitivity")
        title.font = .systemFont(ofSize: 11, weight: .medium)
        title.frame = NSRect(x: 14, y: 43, width: 216, height: 14)
        let badge = NSTextField(labelWithString: "⚡ Instant")
        badge.font = .systemFont(ofSize: 10, weight: .semibold)
        badge.textColor = .systemRed
        badge.alignment = .right
        badge.frame = NSRect(x: 128, y: 43, width: 102, height: 14)
        badge.isHidden = true
        let slider = NSSlider(value: 1, minValue: 0, maxValue: 2, target: self, action: #selector(changeSensitivity(_:)))
        slider.numberOfTickMarks = 3
        slider.allowsTickMarkValuesOnly = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 14, y: 24, width: 216, height: 16)
        let labels = NSView(frame: NSRect(x: 10, y: 6, width: 224, height: 14))
        for (index, label) in ["Light", "Medium", "High"].enumerated() {
            let text = NSTextField(labelWithString: label)
            text.font = .systemFont(ofSize: 10)
            text.alignment = .center
            text.textColor = .secondaryLabelColor
            text.frame = NSRect(x: CGFloat(index) * (224 / 3), y: 0, width: 224 / 3, height: 14)
            labels.addSubview(text)
        }
        container.addSubview(glow)
        container.addSubview(title)
        container.addSubview(badge)
        container.addSubview(slider)
        container.addSubview(labels)
        sensitivitySlider = slider
        sensitivityTitleLabel = title
        sensitivityLevelLabels = labels.subviews.compactMap { $0 as? NSTextField }
        highSensitivityGlow = glow
        highSensitivityBadge = badge
        return container
    }

    private func render(_ state: BackgroundMonitoringService.SecurityState) {
        renderedState = state
        // Status reflects the requested simple face-count rule. The separate alert state still
        // applies the screen-facing head-pose gate before it begins flashing.
        let warning = (monitor.latestDetection?.faceCount ?? 0) >= 2 || state == .alert
        let title = warning ? localizedWarning : localizedSecure
        let color: NSColor = warning ? .systemYellow : .systemGreen
        statusMenuItem.title = title
        if state == .alert { startFlashing() }
        else { stopFlashing(); applyIcon(symbolName: state.symbolName, color: color, title: title) }
        statusItem.button?.toolTip = "stopat: \(title)"
    }

    private func applyIcon(symbolName: String, color: NSColor, title: String) {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)?.withSymbolConfiguration(configuration)
        image?.isTemplate = false
        statusItem.button?.image = image
    }

    private func startFlashing() {
        guard flashTimer == nil else { return }
        flashIsDimmed = false
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.flashIsDimmed.toggle()
                self.applyIcon(symbolName: self.renderedState.symbolName, color: self.flashIsDimmed ? .secondaryLabelColor : .systemRed, title: self.localizedWarning)
            }
        }
        applyIcon(symbolName: renderedState.symbolName, color: .systemRed, title: localizedWarning)
    }

    private func stopFlashing() { flashTimer?.invalidate(); flashTimer = nil; flashIsDimmed = false }

    private func updatePreviewAvailability(granted: Bool) {
        showPreviewMenuItem.isEnabled = granted
        showPreviewMenuItem.title = granted ? localizedFaceDetection : "\(localizedFaceDetection) (\(localizedGrantCameraAccess))"
    }

    private func applyLanguage() {
        languageMenuItem.title = "\(localizedLanguage): \(language.title)"
        quitMenuItem.title = localizedQuit
        showCenterMessageMenuItem.title = localizedShowBlurMessage
        customizeMessageMenuItem.title = localizedCustomizeBlurMessage
        sensitivityTitleLabel?.stringValue = localizedSensitivity
        highSensitivityBadge?.stringValue = "⚡ \(localizedInstant)"
        for (label, title) in zip(sensitivityLevelLabels, localizedSensitivityLevels) {
            label.stringValue = title
        }
        languageItems.forEach { option, item in item.state = option == language ? .on : .off }
        updatePreviewAvailability(granted: monitor.cameraPermissionGranted)
        render(monitor.state)
    }

    private var localizedSecure: String { switch language { case .english: "Secure"; case .chinese: "安全"; case .japanese: "安全"; case .korean: "안전" } }
    private var localizedWarning: String { switch language { case .english: "Warning"; case .chinese: "警告"; case .japanese: "警告"; case .korean: "경고" } }
    private var localizedFaceDetection: String { switch language { case .english: "Face Detection"; case .chinese: "人脸检测"; case .japanese: "顔検出"; case .korean: "얼굴 감지" } }
    private var localizedLanguage: String { switch language { case .english: "Language"; case .chinese: "语言"; case .japanese: "言語"; case .korean: "언어" } }
    private var localizedQuit: String { switch language { case .english: "Quit stopat"; case .chinese: "退出 stopat"; case .japanese: "stopatを終了"; case .korean: "stopat 종료" } }
    private var localizedSensitivity: String { switch language { case .english: "Sensitivity"; case .chinese: "灵敏度"; case .japanese: "感度"; case .korean: "감도" } }
    private var localizedSensitivityLevels: [String] { switch language { case .english: ["Light", "Medium", "High"]; case .chinese: ["低", "中", "高"]; case .japanese: ["低", "中", "高"]; case .korean: ["낮음", "중간", "높음"] } }
    private var localizedShowBlurMessage: String { switch language { case .english: "Show Blur Message"; case .chinese: "显示模糊提示"; case .japanese: "ぼかしメッセージを表示"; case .korean: "흐림 메시지 표시" } }
    private var localizedCustomizeBlurMessage: String { switch language { case .english: "Customize Blur Message…"; case .chinese: "自定义模糊提示…"; case .japanese: "ぼかしメッセージをカスタマイズ…"; case .korean: "흐림 메시지 사용자화…" } }
    private var localizedGrantCameraAccess: String { switch language { case .english: "grant camera access first"; case .chinese: "请先允许摄像头访问"; case .japanese: "先にカメラへのアクセスを許可してください"; case .korean: "먼저 카메라 접근을 허용하세요" } }
    private var localizedBlurMessageTitle: String { switch language { case .english: "Blur Message"; case .chinese: "模糊提示"; case .japanese: "ぼかしメッセージ"; case .korean: "흐림 메시지" } }
    private var localizedBlurMessageInfo: String { switch language { case .english: "This message appears in the center of the screen while the blur is active."; case .chinese: "屏幕模糊时，此消息会显示在屏幕中央。"; case .japanese: "画面がぼかされている間、このメッセージが中央に表示されます。"; case .korean: "화면이 흐려지는 동안 이 메시지가 중앙에 표시됩니다." } }
    private var localizedSave: String { switch language { case .english: "Save"; case .chinese: "保存"; case .japanese: "保存"; case .korean: "저장" } }
    private var localizedCancel: String { switch language { case .english: "Cancel"; case .chinese: "取消"; case .japanese: "キャンセル"; case .korean: "취소" } }
    private var localizedInstant: String { switch language { case .english: "Instant"; case .chinese: "即时"; case .japanese: "即時"; case .korean: "즉시" } }

    func statusButtonScreenFrame() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func toggleFacePreview() { onToggleFacePreview() }

    @objc private func toggleCenterMessage() {
        blurController.toggleCenterMessage()
    }

    @objc private func customizeCenterMessage() {
        let alert = NSAlert()
        alert.messageText = localizedBlurMessageTitle
        alert.informativeText = localizedBlurMessageInfo
        alert.addButton(withTitle: localizedSave)
        alert.addButton(withTitle: localizedCancel)
        let field = NSTextField(string: blurController.centerMessage)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        if alert.runModal() == .alertFirstButtonReturn {
            blurController.setCenterMessage(field.stringValue)
        }
    }

    @objc private func changeSensitivity(_ slider: NSSlider) {
        guard let value = BackgroundMonitoringService.Sensitivity(rawValue: slider.integerValue) else { return }
        monitor.setSensitivity(value)
    }

    private func setSensitivityEffect(for sensitivity: BackgroundMonitoringService.Sensitivity) {
        let isHigh = sensitivity == .high
        sensitivityTitleLabel?.textColor = isHigh ? .systemRed : .labelColor
        highSensitivityBadge?.isHidden = !isHigh
        highSensitivityGlow?.setActive(isHigh)
    }
    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let title = sender.representedObject as? String,
              let selection = Language.allCases.first(where: { $0.title == title }) else { return }
        language = selection
        applyLanguage()
    }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}

/// A compact red pulse confirms that High enables immediate protection without taking over the menu.
private final class HighSensitivityGlowView: NSView {
    private let glowLayer = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glowLayer.fillColor = NSColor.systemRed.withAlphaComponent(0.10).cgColor
        glowLayer.strokeColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
        glowLayer.lineWidth = 1
        layer?.addSublayer(glowLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        glowLayer.frame = bounds
        glowLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )
    }

    func setActive(_ active: Bool) {
        isHidden = !active
        glowLayer.removeAllAnimations()
        guard active else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 0.35
        pulse.toValue = 1.0
        pulse.duration = 0.75
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        glowLayer.add(pulse, forKey: "highSensitivityPulse")
    }
}
