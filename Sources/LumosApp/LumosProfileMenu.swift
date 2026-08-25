import LumosSpikeCore
import SwiftUI

enum LumosProfileMenuSize {
    case compact
    case regular

    var width: CGFloat {
        switch self {
        case .compact: 132
        case .regular: 240
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .compact: 9
        case .regular: 11
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .compact: 6
        case .regular: 7
        }
    }
}

struct LumosProfileMenu: View {
    @ObservedObject var model: LumosAppModel
    let size: LumosProfileMenuSize

    var body: some View {
        Menu {
            profileSection(title: "内置 Preset", profiles: builtInProfiles)

            if !customProfiles.isEmpty {
                Divider()
                profileSection(title: "我的 Profile", profiles: customProfiles)
            }
        } label: {
            HStack(spacing: 7) {
                Text(model.selectedProfile.name)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, size.horizontalPadding)
            .padding(.vertical, size.verticalPadding)
            .frame(width: size.width)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.07), lineWidth: 1)
            }
        }
        .menuIndicator(.hidden)
        .menuStyle(.borderlessButton)
        .fixedSize()
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
