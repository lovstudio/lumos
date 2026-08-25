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
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            LumosProfilePopover(model: model, isPresented: $isPresented)
        }
        .help("切换 Profile")
        .accessibilityLabel("选择 Profile")
        .accessibilityValue(model.selectedProfile.name)
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
