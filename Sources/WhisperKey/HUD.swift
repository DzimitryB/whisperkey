import AppKit

/// Tiny floating status window shown at the bottom-center of the screen:
/// recording (mic + live level bars + timer) → processing (spinner) → done (checkmark), then fades out.
final class HUD {
    static let shared = HUD()

    private let panel: NSPanel
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let levelView = LevelView()
    private var generation = 0

    private let size = NSSize(width: 230, height: 44)

    private init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .vibrantDark)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        panel.contentView = effect

        iconView.frame = NSRect(x: 14, y: (size.height - 22) / 2, width: 22, height: 22)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        effect.addSubview(iconView)

        levelView.frame = NSRect(x: 44, y: (size.height - 22) / 2, width: 34, height: 22)
        effect.addSubview(levelView)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.frame = NSRect(x: 15, y: (size.height - 18) / 2, width: 18, height: 18)
        spinner.isDisplayedWhenStopped = false
        effect.addSubview(spinner)

        label.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.frame = NSRect(x: 86, y: (size.height - 17) / 2, width: size.width - 96, height: 17)
        effect.addSubview(label)
    }

    // MARK: - States

    func showRecording() {
        generation += 1
        setIcon("mic.fill", tint: .systemRed)
        iconView.isHidden = false
        spinner.stopAnimation(nil)
        levelView.isHidden = false
        levelView.start()
        setLabel("Запись… 0:00", x: 86)
        present()
    }

    func updateLevel(_ level: Float) {
        levelView.update(level: level)
    }

    func updateTime(_ seconds: Int) {
        label.stringValue = String(format: "Запись… %d:%02d", seconds / 60, seconds % 60)
    }

    func showProcessing(text: String = "Распознаю…") {
        generation += 1
        iconView.isHidden = true
        levelView.stop()
        levelView.isHidden = true
        spinner.startAnimation(nil)
        setLabel(text, x: 44)
        present()
    }

    func showDone(success: Bool, text: String) {
        generation += 1
        let gen = generation
        spinner.stopAnimation(nil)
        levelView.stop()
        levelView.isHidden = true
        setIcon(
            success ? "checkmark.circle.fill" : "xmark.circle.fill",
            tint: success ? .systemGreen : .systemRed
        )
        iconView.isHidden = false
        setLabel(text, x: 44)
        present()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.fadeOut()
        }
    }

    func hide() {
        generation += 1
        levelView.stop()
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    // MARK: - Internals

    private func setIcon(_ symbol: String, tint: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        iconView.image = image
        iconView.contentTintColor = tint
    }

    private func setLabel(_ text: String, x: CGFloat) {
        label.stringValue = text
        label.frame = NSRect(
            x: x, y: (size.height - 17) / 2,
            width: size.width - x - 10, height: 17
        )
    }

    private func present() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        let origin = NSPoint(x: f.midX - size.width / 2, y: f.minY + 96)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func fadeOut() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
            self?.panel.alphaValue = 1
        })
    }
}

/// Five small bars dancing to the microphone level.
final class LevelView: NSView {
    private var current: CGFloat = 0
    private var target: CGFloat = 0
    private var phase: CGFloat = 0
    private var timer: Timer?
    private let weights: [CGFloat] = [0.55, 0.85, 1.0, 0.75, 0.5]

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        current = 0
        target = 0
        needsDisplay = true
    }

    func update(level: Float) {
        // Gentle gain so normal speech fills most of the range.
        target = min(1, CGFloat(level) * 3.5)
    }

    private func tick() {
        let rate: CGFloat = target > current ? 0.5 : 0.15 // fast attack, slow decay
        current += (target - current) * rate
        phase += 0.45
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barWidth: CGFloat = 4
        let gap: CGFloat = 3
        let count = weights.count
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        let startX = (bounds.width - totalWidth) / 2
        let maxHeight = bounds.height

        NSColor.white.withAlphaComponent(0.9).setFill()
        for i in 0..<count {
            let wobble = 0.75 + 0.25 * sin(phase + CGFloat(i) * 1.3)
            let h = max(maxHeight * 0.15, maxHeight * current * weights[i] * wobble)
            let rect = NSRect(
                x: startX + CGFloat(i) * (barWidth + gap),
                y: (bounds.height - h) / 2,
                width: barWidth,
                height: h
            )
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
    }
}
