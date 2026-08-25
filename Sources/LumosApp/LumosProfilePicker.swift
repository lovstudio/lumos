import LumosSpikeCore
import SwiftUI

enum LumosProfileSelectorSize {
    case compact
    case regular

    var height: CGFloat {
        switch self {
        case .compact: 40
        case .regular: 44
        }
    }

    var circleSize: CGFloat {
        switch self {
        case .compact: 28
        case .regular: 30
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

    var body: some View {
        Menu {
            profileSection(title: "内置 Preset", profiles: builtInProfiles)

            if !customProfiles.isEmpty {
                Divider()
                profileSection(title: "我的 Profile", profiles: customProfiles)
            }
        } label: {
            HStack(spacing: 10) {
                Text(model.selectedProfile.name)
                    .font(size.font)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 12)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: size.circleSize, height: size.circleSize)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(isHovering ? 0.11 : 0.07))
                    )
            }
            .padding(.leading, 13)
            .padding(.trailing, 7)
            .frame(maxWidth: .infinity)
            .frame(height: size.height)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.052 : 0.034))
            )
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("切换 Profile")
        .accessibilityLabel("选择 Profile")
        .accessibilityValue(model.selectedProfile.name)
    }

    @ViewBuilder
    private func profileSection(title: String, profiles: [LumosProfile]) -> some View {
        if !profiles.isEmpty {
            Section(title) {
                ForEach(profiles) { profile in
                    Button {
                        model.selectProfile(id: profile.id)
                    } label: {
                        if profile.id == model.preferences.selectedProfileID {
                            Label(profile.name, systemImage: "checkmark")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
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
