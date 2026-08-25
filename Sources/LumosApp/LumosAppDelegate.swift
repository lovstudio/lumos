import AppKit
import Darwin
import SwiftUI

@MainActor
final class LumosAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    private static let popoverMenuBarGap: CGFloat = 10

    private let model = LumosAppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var outsideClickMonitor: Any?
    private var terminationSignalSources: [DispatchSourceSignal] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PrivilegedHelperManager.prepare()
        installTerminationSignalHandlers()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 390, height: 610)
        popover.contentViewController = NSHostingController(
            rootView: LumosMenuView(model: model) { [weak self] in
                self?.showSettings()
            }
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )

        model.statusDidChange = { [weak self] in
            self?.updateStatusItem()
        }
        model.activateConfiguredControls()
        updateStatusItem()

        let arguments = Set(ProcessInfo.processInfo.arguments.dropFirst())
        if arguments.contains("--enable-launch-at-login") {
            model.setLaunchAtLogin(true)
            print("Lumos launch-at-login: \(model.launchAtLoginState.detail)")
        }
        if arguments.contains("--disable-launch-at-login") {
            model.setLaunchAtLogin(false)
            print("Lumos launch-at-login: \(model.launchAtLoginState.detail)")
        }
        if arguments.contains("--show-menu") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showPopover()
            }
        }
        if arguments.contains("--show-settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showSettings()
            }
        }

        print("Lumos dev ready pid=\(getpid()) mode=menu-bar")
        fflush(stdout)
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources.removeAll()
        stopOutsideClickMonitoring()
        NotificationCenter.default.removeObserver(self)
        model.shutdown()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        settingsWindow = nil
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            closePopover(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        PrivilegedHelperManager.prepare()
        model.refreshAll()
        NSApplication.shared.activate(ignoringOtherApps: true)
        popover.show(
            relativeTo: button.bounds,
            of: button,
            preferredEdge: .minY
        )
        positionPopoverCloseToMenuBar(from: button)
        startOutsideClickMonitoring()
    }

    private func closePopover(_ sender: Any?) {
        guard popover.isShown else {
            stopOutsideClickMonitoring()
            return
        }
        popover.performClose(sender)
    }

    private func positionPopoverCloseToMenuBar(from button: NSStatusBarButton) {
        guard let statusItemWindow = button.window,
              let popoverWindow = popover.contentViewController?.view.window,
              let screen = statusItemWindow.screen else { return }

        var frame = popoverWindow.frame
        let desiredMaximumY = statusItemWindow.frame.minY - Self.popoverMenuBarGap
        frame.origin.y = min(
            desiredMaximumY - frame.height,
            screen.visibleFrame.maxY - frame.height
        )
        frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)
        popoverWindow.setFrameOrigin(frame.origin)
    }

    private func startOutsideClickMonitoring() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover(nil)
            }
        }
    }

    private func stopOutsideClickMonitoring() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler {
                NSApplication.shared.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    @objc private func applicationDidResignActive() {
        closePopover(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        stopOutsideClickMonitoring()
    }

    func showSettings() {
        closePopover(nil)
        PrivilegedHelperManager.prepare()
        model.refreshAll()

        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: LumosSettingsView(model: model))
        let window = NSWindow(contentViewController: controller)
        window.title = "Lumos 设置"
        window.setContentSize(NSSize(width: 820, height: 580))
        window.minSize = NSSize(width: 760, height: 520)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbolName = model.isGuardEnabled ? "lightbulb.fill" : "lightbulb"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: model.statusText
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = model.statusText
    }

}
