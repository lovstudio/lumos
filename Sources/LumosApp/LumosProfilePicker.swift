import LumosSpikeCore
import SwiftUI

struct LumosPresetSegmentedPicker: View {
    @ObservedObject var model: LumosAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("运行方案", selection: builtInSelection) {
                ForEach(builtInProfiles) { profile in
                    Text(profile.presetKind.title)
                        .tag(Optional(profile.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel("运行方案")
            .accessibilityValue(model.selectedProfile.name)

            if !model.selectedProfile.isBuiltIn {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(model.selectedProfile.name)
                        .lineLimit(1)
                    Spacer()
                    Text("自定义 Profile")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .padding(.horizontal, 2)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var builtInSelection: Binding<UUID?> {
        Binding(
            get: {
                model.selectedProfile.isBuiltIn
                    ? model.preferences.selectedProfileID
                    : nil
            },
            set: { id in
                guard let id else { return }
                model.selectProfile(id: id)
            }
        )
    }

    private var builtInProfiles: [LumosProfile] {
        model.preferences.profiles.filter(\.isBuiltIn)
    }
}

struct LumosProfileSelectionList: View {
    @ObservedObject var model: LumosAppModel

    var body: some View {
        VStack(spacing: 0) {
            profileGroup(title: "内置 Preset", profiles: builtInProfiles)

            if !customProfiles.isEmpty {
                Divider().padding(.leading, 54)
                profileGroup(title: "我的 Profile", profiles: customProfiles)
            }
        }
    }

    @ViewBuilder
    private func profileGroup(title: String, profiles: [LumosProfile]) -> some View {
        if !profiles.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 11)
                    .padding(.bottom, 5)

                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    LumosProfileSelectionRow(
                        profile: profile,
                        isSelected: profile.id == model.preferences.selectedProfileID
                    ) {
                        model.selectProfile(id: profile.id)
                    }

                    if index != profiles.count - 1 {
                        Divider().padding(.leading, 54)
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

private struct LumosProfileSelectionRow: View {
    let profile: LumosProfile
    let isSelected: Bool
    let select: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(profile.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(profile.name)
        .accessibilityValue(isSelected ? "已选择" : profile.summary)
    }

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(0.09)
        }
        return isHovering ? Color.primary.opacity(0.035) : .clear
    }

    private var iconName: String {
        guard profile.isBuiltIn else { return "slider.horizontal.3" }
        return switch profile.presetKind {
        case .taskGuard: "terminal"
        case .alwaysReachable: "antenna.radiowaves.left.and.right"
        case .keepDisplayAwake: "display"
        }
    }
}
