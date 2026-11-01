import AppKit
import FenceCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var reconfigureWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        Guardian.spawn()
        observeSystem()
        model.refreshStatus()

        if !AXIsProcessTrusted() {
            // Shows the system prompt that leads to Privacy & Security ▸ Accessibility.
            let key = "AXTrustedCheckOptionPrompt" as CFString
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        startTapIfPossible()
        if !model.accessibilityGranted || model.fencedUUID == nil { showSettings() }

        // Picks up an Accessibility grant (or revocation) and keeps stats fresh.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.engine.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func tick() {
        let wasGranted = model.accessibilityGranted
        model.refreshStatus()
        if model.accessibilityGranted, !model.engine.isRunning {
            startTapIfPossible()
        } else if !model.accessibilityGranted, wasGranted {
            // Revoked: the tap has gone deaf. Let go and tear it down; it is
            // rebuilt when the grant comes back.
            model.engine.stop()
            model.setTapRunning(false)
        }
        model.writeStats()
        let request = AppModel.statsURL.deletingLastPathComponent().appendingPathComponent("dump-trace")
        if FileManager.default.fileExists(atPath: request.path) {
            try? FileManager.default.removeItem(at: request)
            model.engine.dumpTrace(to: request.deletingLastPathComponent().appendingPathComponent("trace.csv"))
        }
    }

    private func startTapIfPossible() {
        guard AXIsProcessTrusted() else { return }
        model.pushConfig()
        model.setTapRunning(model.engine.start())
    }

    // MARK: System events

    private func observeSystem() {
        let ws = NSWorkspace.shared.notificationCenter
        let suspendOn: [Notification.Name] = [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                                              NSWorkspace.sessionDidResignActiveNotification]
        let resumeOn: [Notification.Name] = [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                                             NSWorkspace.sessionDidBecomeActiveNotification]
        for name in suspendOn {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] n in
                let reason = n.name.rawValue
                MainActor.assumeIsolated { self?.model.engine.suspend(reason: reason) }
            }
        }
        for name in resumeOn {
            ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleReconfigure() }
            }
        }
        ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.localizedName ?? "?"
            MainActor.assumeIsolated { self?.model.engine.mark("activate \(app)") }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconfigure() }
        }
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
    }

    /// The display callback suspends at once (it may run before AppKit knows);
    /// geometry is rebuilt after things settle.
    nonisolated func displaysChanging(_ flags: CGDisplayChangeSummaryFlags) {
        model.engine.suspend(reason: "display reconfiguration")
        DispatchQueue.main.async { [weak self] in self?.scheduleReconfigure() }
    }

    private func scheduleReconfigure() {
        model.engine.suspend(reason: "reconfiguring")
        reconfigureWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.refreshDisplays()
                self.model.engine.resume()
                self.keepSettingsOffFencedDisplay()
            }
        }
        reconfigureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Settings window

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Cursor Fence Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.delegate = self
            w.setFrameAutosaveName("CursorFenceSettings")
            if !w.setFrameUsingName("CursorFenceSettings") { w.center() }
            settingsWindow = w
        }
        model.refreshDisplays()
        model.refreshStatus()
        keepSettingsOffFencedDisplay()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// The Settings window is ours to draw too: never on the fenced display.
    private func keepSettingsOffFencedDisplay() {
        guard let w = settingsWindow, let g = model.geometry else { return }
        let h = Displays.mainDisplayHeight
        let frameCG = Feedback.cgRect(fromAppKit: w.frame, mainDisplayHeight: h)
        guard overlapArea(frameCG, g.fenced) > 0,
              let target = NSScreen.screens.first(where: { s in
                  overlapArea(Feedback.cgRect(fromAppKit: s.frame, mainDisplayHeight: h), g.fenced) == 0
              }) else { return }
        let vf = target.visibleFrame
        w.setFrameOrigin(NSPoint(x: vf.midX - w.frame.width / 2, y: vf.midY - w.frame.height / 2))
    }

    func windowDidMove(_ notification: Notification) {
        keepSettingsOffFencedDisplay()
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Cursor Fence", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Cursor Fence", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cursor Fence", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}

private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ info: UnsafeMutableRawPointer?) {
    guard let info else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(info).takeUnretainedValue()
    // Delivered on the main thread (the app's run loop registered it).
    delegate.displaysChanging(flags)
}
