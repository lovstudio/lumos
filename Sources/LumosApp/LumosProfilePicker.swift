import AppKit
import LumosSpikeCore
import SwiftUI

enum LumosProfileSelectorSize {
    case compact
    case regular

    var circleSize: CGFloat {
        switch self {
        case .compact: 24
        case .regular: 26
        }
    }

    var maximumTextWidth: CGFloat {
        switch self {
        case .compact: 170
        case .regular: 230
        }
    }

    var font: Font {
        switch self {
        case .compact: .callout
        case .regular: .body
        }
    }
}

struct LumosProfileSelector: View {
    @ObservedObject var model: LumosAppModel
    let size: LumosProfileSelectorSize
    @State private var isHovering = false
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(model.selectedProfile.name)
                    .font(size.font)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: size.maximumTextWidth, alignment: .trailing)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: size.circleSize, height: size.circleSize)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isHovering || isPresented ? 0.12 : 0.075))
                    )
                    .background {
                        LumosAnchoredPopover(
                            isPresented: $isPresented,
                            content: LumosProfilePopover(
                                model: model,
                                isPresented: $isPresented
                            )
                        )
                        .frame(width: size.circleSize, height: size.circleSize)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("切换 Profile")
        .accessibilityLabel("选择 Profile")
        .accessibilityValue(model.selectedProfile.name)
    }
}

private struct LumosAnchoredPopover<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: Content

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> NSView {
        let anchor = NSView()
        anchor.setAccessibilityElement(false)
        return anchor
    }

    func updateNSView(_ anchor: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        if let hostingController = coordinator.popover.contentViewController
            as? NSHostingController<Content> {
            hostingController.rootView = content
        } else {
            coordinator.popover.contentViewController = NSHostingController(rootView: content)
        }

        if isPresented {
            coordinator.present(from: anchor)
        } else {
            coordinator.close()
        }
    }

    static func dismantleNSView(_ anchor: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        let popover = NSPopover()
        var isPresented: Binding<Bool>

        init(isPresented: Binding<Bool>) {
            self.isPresented = isPresented
            super.init()

            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(applicationDidResignActive),
                name: NSApplication.didResignActiveNotification,
                object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func present(from anchor: NSView) {
            guard !popover.isShown else { return }

            guard anchor.window != nil else {
                DispatchQueue.main.async { [weak self, weak anchor] in
                    guard let self,
                          let anchor,
                          anchor.window != nil,
                          self.isPresented.wrappedValue else { return }
                    self.present(from: anchor)
                }
                return
            }

            popover.show(
                relativeTo: anchor.bounds,
                of: anchor,
                preferredEdge: .minY
            )
        }

        func close() {
            guard popover.isShown else { return }
            popover.performClose(nil)
        }

        @objc private func applicationDidResignActive() {
            close()
        }

        func popoverDidClose(_ notification: Notification) {
            guard isPresented.wrappedValue else { return }
            DispatchQueue.main.async { [weak self] in
                self?.isPresented.wrappedValue = false
            }
        }
    }
}

private struct LumosProfilePopover: View {
    @ObservedObject var model: LumosAppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("运行方案")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 8)

            profileGroup(title: "内置 Preset", profiles: builtInProfiles)

            if !customProfiles.isEmpty {
                Divider().padding(.vertical, 4)
                profileGroup(title: "我的 Profile", profiles: customProfiles)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 270)
    }

    @ViewBuilder
    private func profileGroup(title: String, profiles: [LumosProfile]) -> some View {
        if !profiles.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)

            ForEach(profiles) { profile in
                Button {
                    model.selectProfile(id: profile.id)
                    isPresented = false
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(profile.name)
                                .foregroundStyle(.primary)
                            Text(profile.presetKind.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        if profile.id == model.preferences.selectedProfileID {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(
                    profile.id == model.preferences.selectedProfileID ? "已选择" : ""
                )
            }
        }
    }

    private var builtInProfiles: [LumosProfile] {
        model.preferences.profiles.filter(\.isBuiltIn)
    }

    private var customProfiles: [LumosProfile] {
        model.preferences.profiles.filter { !$0.isBuiltIn }
    }
}
