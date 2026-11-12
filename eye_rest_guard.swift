import Cocoa
import QuartzCore
import Carbon.HIToolbox

// MARK: - Configuration
enum Cfg {
    static let interval: TimeInterval = envSeconds("EYE_INTERVAL", default: 30 * 60)
    static let duration: TimeInterval = envSeconds("EYE_DURATION", default: 40)

    // Global hotkey to trigger the break on demand.
    // ⌘ + ;   (change these two lines to rebind)
    static let hotkeyKeyCode: UInt32   = UInt32(kVK_ANSI_Semicolon)
    static let hotkeyModifiers: UInt32 = UInt32(cmdKey)

    // Warm-night palette
    static let bg    = NSColor(calibratedRed: 0.11, green: 0.08, blue: 0.06, alpha: 0.86)
    static let amber = NSColor(calibratedRed: 0.96, green: 0.66, blue: 0.32, alpha: 1.0)
    static let cream = NSColor(calibratedRed: 0.98, green: 0.94, blue: 0.86, alpha: 1.0)

    static let startSound = "Glass"
    static let endSound   = "Submarine"

    static func envSeconds(_ key: String, default d: TimeInterval) -> TimeInterval {
        if let s = ProcessInfo.processInfo.environment[key], let v = TimeInterval(s), v > 0 { return v }
        return d
    }
}

// Diagnostic logging, silent unless EYE_DEBUG is set.
func dbg(_ s: String) {
    guard ProcessInfo.processInfo.environment["EYE_DEBUG"] != nil else { return }
    FileHandle.standardError.write(("[eye] " + s + "\n").data(using: .utf8)!)
}

// MARK: - A borderless window that can still take keyboard focus
final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - The 40-second break overlay (spans every screen)
final class OverlayController: NSObject {
    private(set) var isShowing = false
    private var windows: [OverlayWindow] = []
    private var countdownLabels: [NSTextField] = []
    private var heartbeat: Timer?
    private var endDate = Date()
    private var keyMonitor: Any?
    private var escTimes: [Date] = []
    private var onDismiss: (() -> Void)?
    private var previousApp: NSRunningApplication?

    func show(duration: TimeInterval, onDismiss: @escaping () -> Void) {
        guard !isShowing else { return }
        isShowing = true
        self.onDismiss = onDismiss
        self.endDate = Date().addingTimeInterval(duration)

        // Remember who held keyboard focus before we steal it, so we can hand it back on finish.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        } else {
            previousApp = nil
        }
        dbg("captured previousApp=\(previousApp?.localizedName ?? "nil")")

        NSApp.activate(ignoringOtherApps: true)
        play(Cfg.startSound)

        for screen in NSScreen.screens {
            windows.append(makeWindow(for: screen))
        }
        windows.first?.makeKeyAndOrderFront(nil)

        for w in windows {
            w.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.8
                w.animator().alphaValue = 1
            }
        }

        // Swallow every keystroke so nothing leaks to the app behind; watch for triple-Esc escape.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isShowing else { return event }
            if event.keyCode == 53 { self.registerEsc() }
            return nil
        }

        heartbeat = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        updateCountdown()
    }

    private func registerEsc() {
        let now = Date()
        escTimes.append(now)
        escTimes = escTimes.filter { now.timeIntervalSince($0) <= 1.5 }
        if escTimes.count >= 3 { finish(early: true) }
    }

    private func tick() {
        if Date() >= endDate { finish(early: false); return }
        updateCountdown()
    }

    private func updateCountdown() {
        let remaining = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
        for label in countdownLabels { label.stringValue = "\(remaining)" }
    }

    private func finish(early: Bool) {
        guard isShowing else { return }
        isShowing = false
        heartbeat?.invalidate(); heartbeat = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        escTimes.removeAll()
        if !early { play(Cfg.endSound) }

        // Hand keyboard focus back to whatever app the user was in before the break.
        let prev = previousApp
        previousApp = nil
        dbg("restoring focus to \(prev?.localizedName ?? "nil")")
        prev?.activate()
        NSApp.deactivate()

        let toClose = windows
        windows.removeAll()
        countdownLabels.removeAll()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.8
            for w in toClose { w.animator().alphaValue = 0 }
        }, completionHandler: {
            for w in toClose { w.close() }
        })
        onDismiss?()
        onDismiss = nil
    }

    // MARK: window + content construction
    private func makeWindow(for screen: NSScreen) -> OverlayWindow {
        let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless,
                              backing: .buffered, defer: false, screen: screen)
        w.isReleasedWhenClosed = false
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = makeContentView(size: screen.frame.size)
        return w
    }

    private func makeContentView(size: NSSize) -> NSView {
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = Cfg.bg.cgColor

        let cx = size.width / 2
        let cy = size.height / 2

        // Breathing circle
        let ring = NSView(frame: NSRect(x: cx - 130, y: cy + 20, width: 260, height: 260))
        ring.wantsLayer = true
        if let host = ring.layer {
            let circle = CAShapeLayer()
            let d: CGFloat = 200
            let inset: CGFloat = (260 - d) / 2
            circle.path = CGPath(ellipseIn: CGRect(x: inset, y: inset, width: d, height: d), transform: nil)
            circle.fillColor = Cfg.amber.withAlphaComponent(0.12).cgColor
            circle.strokeColor = Cfg.amber.cgColor
            circle.lineWidth = 3
            circle.shadowColor = Cfg.amber.cgColor
            circle.shadowOffset = .zero
            circle.shadowRadius = 26
            circle.shadowOpacity = 0.55
            circle.bounds = CGRect(x: 0, y: 0, width: 260, height: 260)
            circle.position = CGPoint(x: 130, y: 130)
            host.addSublayer(circle)

            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.75, 1.18, 0.75]
            scale.keyTimes = [0, 0.4, 1.0]          // 4s inhale, 6s exhale
            scale.duration = 10
            scale.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut),
                                     CAMediaTimingFunction(name: .easeInEaseOut)]
            scale.repeatCount = .infinity
            circle.add(scale, forKey: "breathe")

            let glow = CAKeyframeAnimation(keyPath: "shadowRadius")
            glow.values = [16, 40, 16]
            glow.keyTimes = [0, 0.4, 1.0]
            glow.duration = 10
            glow.repeatCount = .infinity
            circle.add(glow, forKey: "glow")
        }
        root.addSubview(ring)

        // Title
        let title = label("看向窗外，望向远处", size: 40, color: Cfg.cream, weight: .medium)
        title.frame.origin = NSPoint(x: cx - title.frame.width / 2, y: cy - 30)
        root.addSubview(title)

        // Subtitle
        let sub = label("让眼睛离开屏幕，眺望最远处", size: 18, color: Cfg.cream.withAlphaComponent(0.7))
        sub.frame.origin = NSPoint(x: cx - sub.frame.width / 2, y: cy - 70)
        root.addSubview(sub)

        // Countdown number
        let count = label("\(Int(ceil(Cfg.duration)))", size: 66, color: Cfg.amber, weight: .semibold)
        count.frame = NSRect(x: cx - 100, y: cy - 165, width: 200, height: 80)
        count.alignment = .center
        countdownLabels.append(count)
        root.addSubview(count)

        // "秒后可继续"
        let hint = label("秒后可继续", size: 16, color: Cfg.cream.withAlphaComponent(0.6))
        hint.frame.origin = NSPoint(x: cx - hint.frame.width / 2, y: cy - 195)
        root.addSubview(hint)

        // Escape affordance
        let esc = label("（如需提前结束，连按三次 Esc）", size: 13, color: Cfg.cream.withAlphaComponent(0.35))
        esc.frame.origin = NSPoint(x: cx - esc.frame.width / 2, y: 60)
        root.addSubview(esc)

        return root
    }

    private func label(_ s: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = NSFont.systemFont(ofSize: size, weight: weight)
        t.textColor = color
        t.alignment = .center
        t.isBezeled = false
        t.drawsBackground = false
        t.isEditable = false
        t.isSelectable = false
        t.sizeToFit()
        return t
    }

    private func play(_ name: String) {
        NSSound(named: NSSound.Name(name))?.play()
    }
}

// MARK: - App: headless daemon + on-demand control panel (summoned via SIGUSR1)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overlay = OverlayController()
    private var heartbeat: Timer?
    private var signalSource: DispatchSourceSignal?
    private var nextFire = Date().addingTimeInterval(Cfg.interval)
    private var pausedUntil: Date?
    private var screenOn = true
    private var panel: NSWindow?
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)   // no Dock icon, no menu bar item
        registerHotkey()

        let wc = NSWorkspace.shared.notificationCenter
        wc.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        wc.addObserver(self, selector: #selector(screensWoke),  name: NSWorkspace.screensDidWakeNotification,  object: nil)

        // SIGUSR1 = "summon the control panel" (sent by the 护眼控制 app)
        signal(SIGUSR1, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        src.setEventHandler { [weak self] in self?.showControlPanel() }
        src.resume()
        signalSource = src

        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.checkTick()
        }
    }

    // MARK: global hotkey (Carbon RegisterEventHotKey — no Accessibility permission needed)
    private func registerHotkey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData = userData else { return noErr }
                let me = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.hotkeyFired() }
                return noErr
            },
            1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x45594547) /* 'EYEG' */, id: 1)
        let status = RegisterEventHotKey(Cfg.hotkeyKeyCode, Cfg.hotkeyModifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &hotKeyRef)
        dbg("RegisterEventHotKey status=\(status)")
    }

    private func hotkeyFired() {
        dbg("hotkeyFired")
        guard !overlay.isShowing else { return }
        panel?.orderOut(nil)
        overlay.show(duration: Cfg.duration) { [weak self] in
            guard let self = self else { return }
            if self.pausedUntil == nil { self.nextFire = Date().addingTimeInterval(Cfg.interval) }
            self.refreshPanelIfVisible()
        }
    }

    private func checkTick() {
        guard !overlay.isShowing, screenOn else { return }
        let now = Date()
        if let p = pausedUntil {
            if now < p { return }
            pausedUntil = nil
            nextFire = now.addingTimeInterval(Cfg.interval)
            refreshPanelIfVisible()
            return
        }
        if now >= nextFire {
            overlay.show(duration: Cfg.duration) { [weak self] in
                guard let self = self else { return }
                self.nextFire = Date().addingTimeInterval(Cfg.interval)
                self.refreshPanelIfVisible()
            }
        }
    }

    @objc private func screensSlept() { screenOn = false }

    @objc private func screensWoke() {
        screenOn = true
        // Screen was off => user rested; start a fresh countdown on wake (unless paused).
        if pausedUntil == nil {
            nextFire = Date().addingTimeInterval(Cfg.interval)
            refreshPanelIfVisible()
        }
    }

    // MARK: control panel
    private func showControlPanel() {
        NSApp.activate(ignoringOtherApps: true)
        let w: NSWindow = panel ?? {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
                               styleMask: [.titled, .closable],
                               backing: .buffered, defer: false)
            win.title = "护眼守卫"
            win.isReleasedWhenClosed = false
            panel = win
            return win
        }()
        w.contentView = buildPanelContent()
        w.center()
        w.makeKeyAndOrderFront(nil)
    }

    private func refreshPanelIfVisible() {
        if let w = panel, w.isVisible { w.contentView = buildPanelContent() }
    }

    private func buildPanelContent() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let status = NSTextField(labelWithString: statusText())
        status.font = .systemFont(ofSize: 13)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.isBezeled = false; status.drawsBackground = false; status.isEditable = false
        stack.addArrangedSubview(status)

        stack.addArrangedSubview(panelButton("暂停 1 小时", #selector(pauseHour)))
        stack.addArrangedSubview(panelButton("今天不再提醒", #selector(pauseToday)))
        if pausedUntil != nil {
            stack.addArrangedSubview(panelButton("恢复提醒", #selector(resume)))
        }
        stack.addArrangedSubview(panelButton("立即测试一次", #selector(testNow)))
        stack.addArrangedSubview(panelButton("退出护眼守卫", #selector(quit)))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func panelButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return b
    }

    private func statusText() -> String {
        if let p = pausedUntil { return "已暂停至 \(hhmm(p))" }
        return "下次提醒：\(hhmm(nextFire))"
    }

    private func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    @objc private func pauseHour() { pausedUntil = Date().addingTimeInterval(3600); refreshPanelIfVisible() }
    @objc private func pauseToday() {
        let cal = Calendar.current
        if let midnight = cal.nextDate(after: Date(),
                                       matching: DateComponents(hour: 0, minute: 0, second: 0),
                                       matchingPolicy: .nextTime) {
            pausedUntil = midnight
        } else {
            pausedUntil = Date().addingTimeInterval(8 * 3600)
        }
        refreshPanelIfVisible()
    }
    @objc private func resume() { pausedUntil = nil; nextFire = Date().addingTimeInterval(Cfg.interval); refreshPanelIfVisible() }
    @objc private func testNow() {
        panel?.orderOut(nil)
        overlay.show(duration: Cfg.duration) { [weak self] in
            guard let self = self else { return }
            if self.pausedUntil == nil { self.nextFire = Date().addingTimeInterval(Cfg.interval) }
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
