import AppKit
import Darwin
import SwiftUI

@MainActor
final class LumosAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = LumosAppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 390, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: LumosMenuView(model: model) { [weak self] in
                self?.showSettings()
            }
        )

        model.statusDidChange = { [weak self] in
            self?.updateStatusItem()
        }
        updateStatusItem()

        let arguments = Set(ProcessInfo.processInfo.arguments.dropFirst())
        if arguments.contains("--start-guard") {
            model.startGuard()
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
        model.shutdown()
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        settingsWindow = nil
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        model.refreshAll()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func showSettings() {
        popover.performClose(nil)
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
        let symbolName = model.isGuardActive ? "lightbulb.fill" : "lightbulb"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: model.statusText
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = model.statusText
    }

}
