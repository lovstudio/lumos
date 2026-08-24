import AppKit
import Darwin
import Foundation
import SwiftUI
import LumosSpikeCore

@MainActor
final class LumosAppModel: ObservableObject {
    @Published private(set) var systemLeaseActive = false
    @Published private(set) var displayLeaseActive = false
    @Published private(set) var systemState = SystemStateProbe.snapshot()
    @Published private(set) var lastError: String?

    var statusDidChange: (() -> Void)?

    private var systemAssertion: PowerAssertion?
    private var displayAssertion: PowerAssertion?

    var isProtecting: Bool {
        systemLeaseActive || displayLeaseActive
    }

    var statusText: String {
        switch (systemLeaseActive, displayLeaseActive) {
        case (true, true):
            "系统与显示器保护已开启。"
        case (true, false):
            "任务继续运行，显示器可以熄灭。"
        case (false, true):
            "Lumos 正在保持屏幕亮起。"
        case (false, false):
            "没有正在守护的任务。"
        }
    }

    var thermalText: String {
        switch systemState.thermalState {
        case .nominal: "温度正常"
        case .fair: "温度略高"
        case .serious: "温度较高"
        case .critical: "温度严重"
        case .unknown: "温度未知"
        }
    }

    var powerModeText: String {
        systemState.lowPowerModeEnabled ? "低电量模式已开启" : "低电量模式未开启"
    }

    func refreshSystemState() {
        systemState = SystemStateProbe.snapshot()
    }

    func toggleSystemLease() {
        if systemAssertion != nil {
            releaseSystemLease()
            return
        }

        do {
            systemAssertion = try PowerAssertion(
                kind: .systemIdleSleep,
                reason: "Lumos 任务守护"
            )
            systemLeaseActive = true
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        statusDidChange?()
    }

    func toggleDisplayLease() {
        if displayAssertion != nil {
            releaseDisplayLease()
            return
        }

        do {
            displayAssertion = try PowerAssertion(
                kind: .displayIdleSleep,
                reason: "Lumos 保持亮屏"
            )
            displayLeaseActive = true
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        statusDidChange?()
    }

    func stopAll() {
        releaseSystemLease(notify: false)
        releaseDisplayLease(notify: false)
        statusDidChange?()
    }

    private func releaseSystemLease(notify: Bool = true) {
        do {
            try systemAssertion?.release()
            systemAssertion = nil
            systemLeaseActive = false
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        if notify { statusDidChange?() }
    }

    private func releaseDisplayLease(notify: Bool = true) {
        do {
            try displayAssertion?.release()
            displayAssertion = nil
            displayLeaseActive = false
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
        if notify { statusDidChange?() }
    }
}

struct LumosMenuView: View {
    @ObservedObject var model: LumosAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            status
            controls
            systemState

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: model.isProtecting ? "lightbulb.fill" : "lightbulb")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(model.isProtecting ? Color.accentColor : .secondary)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text("Lumos")
                    .font(.headline)
                Text("为未完成的事情，留一盏灯。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("当前状态")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(model.statusText)
                .font(.body)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            controlButton(
                title: model.systemLeaseActive ? "停止任务守护" : "开启任务守护",
                detail: "允许熄屏，防止系统因空闲休眠",
                systemImage: model.systemLeaseActive ? "stop.circle.fill" : "moon.zzz",
                active: model.systemLeaseActive,
                action: model.toggleSystemLease
            )

            controlButton(
                title: model.displayLeaseActive ? "停止保持亮屏" : "保持亮屏",
                detail: "防止显示器因空闲自动熄灭",
                systemImage: model.displayLeaseActive ? "stop.circle.fill" : "display",
                active: model.displayLeaseActive,
                action: model.toggleDisplayLease
            )
        }
    }

    private func controlButton(
        title: String,
        detail: String,
        systemImage: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(active ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var systemState: some View {
        HStack(spacing: 16) {
            Label(model.powerModeText, systemImage: "battery.75percent")
            Label(model.thermalText, systemImage: "thermometer.medium")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack {
            Button("刷新") {
                model.refreshSystemState()
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)

            if model.isProtecting {
                Button("停止所有保护") {
                    model.stopAll()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }

            Spacer()

            Button("退出 Lumos") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
        }
        .font(.caption)
    }
}

@MainActor
final class LumosAppDelegate: NSObject, NSApplicationDelegate {
    private let model = LumosAppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?

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
        popover.contentViewController = NSHostingController(rootView: LumosMenuView(model: model))

        model.statusDidChange = { [weak self] in
            self?.updateStatusItem()
        }
        updateStatusItem()

        print("Lumos dev ready pid=\(getpid()) mode=menu-bar")
        fflush(stdout)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopAll()
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        model.refreshSystemState()
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbolName = model.isProtecting ? "lightbulb.fill" : "lightbulb"
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: model.statusText
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = model.statusText
    }
}

@main
enum LumosAppEntry {
    @MainActor
    static func main() {
        guard let instanceLock = LumosInstanceLock() else {
            print("Lumos dev is already running")
            return
        }

        let application = NSApplication.shared
        let delegate = LumosAppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime((delegate, instanceLock)) {}
    }
}

final class LumosInstanceLock {
    private let fileDescriptor: Int32

    init?() {
        let path = "/tmp/ai.lovstudio.lumos.dev.\(getuid()).lock"
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return nil }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        fileDescriptor = descriptor
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
    }
}
