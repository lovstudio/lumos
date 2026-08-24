import Foundation

public struct AtomicControlPreferences: Codable, Equatable, Sendable {
    public var preventDisplayIdleSleep: Bool
    public var preventSystemIdleSleep: Bool
    public var requestClamshellProtection: Bool
    public var preferLowPowerMode: Bool

    public init(
        preventDisplayIdleSleep: Bool,
        preventSystemIdleSleep: Bool,
        requestClamshellProtection: Bool,
        preferLowPowerMode: Bool
    ) {
        self.preventDisplayIdleSleep = preventDisplayIdleSleep
        self.preventSystemIdleSleep = preventSystemIdleSleep
        self.requestClamshellProtection = requestClamshellProtection
        self.preferLowPowerMode = preferLowPowerMode
    }
}

public struct WatchedApplication: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var displayName: String
    public var executablePath: String?

    public init(id: String, displayName: String, executablePath: String?) {
        self.id = id
        self.displayName = displayName
        self.executablePath = executablePath
    }
}

public struct LumosProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var summary: String
    public var controls: AtomicControlPreferences
    public var watchedApplicationIDs: [String]
    public let isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        controls: AtomicControlPreferences,
        watchedApplicationIDs: [String] = [],
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.controls = controls
        self.watchedApplicationIDs = watchedApplicationIDs
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case controls
        case watchedApplicationIDs
        case isBuiltIn
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        controls = try container.decode(AtomicControlPreferences.self, forKey: .controls)
        watchedApplicationIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .watchedApplicationIDs
        ) ?? []
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(summary, forKey: .summary)
        try container.encode(controls, forKey: .controls)
        try container.encode(watchedApplicationIDs, forKey: .watchedApplicationIDs)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
    }
}

public struct LumosPreferences: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let agentProfileID = UUID(uuidString: "A63E0001-4C7D-4AD7-9000-000000000001")!

    public var version: Int
    public var selectedProfileID: UUID
    public var activeControls: AtomicControlPreferences
    public var profiles: [LumosProfile]
    public var watchedApplications: [WatchedApplication]

    public init(
        version: Int = schemaVersion,
        selectedProfileID: UUID,
        activeControls: AtomicControlPreferences,
        profiles: [LumosProfile],
        watchedApplications: [WatchedApplication]
    ) {
        self.version = version
        self.selectedProfileID = selectedProfileID
        self.activeControls = activeControls
        self.profiles = profiles
        self.watchedApplications = watchedApplications
        normalize()
    }

    public static var agentMode: LumosProfile {
        LumosProfile(
            id: agentProfileID,
            name: "Agent 模式",
            summary: "允许熄屏，保持任务运行，并建议使用低功耗模式。",
            controls: AtomicControlPreferences(
                preventDisplayIdleSleep: false,
                preventSystemIdleSleep: true,
                requestClamshellProtection: false,
                preferLowPowerMode: true
            ),
            isBuiltIn: true
        )
    }

    public static var defaults: LumosPreferences {
        let agent = agentMode
        return LumosPreferences(
            selectedProfileID: agent.id,
            activeControls: agent.controls,
            profiles: [agent],
            watchedApplications: []
        )
    }

    public var selectedProfile: LumosProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    public mutating func selectProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        selectedProfileID = profile.id
        activeControls = profile.controls
    }

    @discardableResult
    public mutating func duplicateSelectedProfile(name: String) -> LumosProfile {
        let source = selectedProfile ?? Self.agentMode
        let profile = LumosProfile(
            name: name,
            summary: "基于“\(source.name)”创建的自定义方案。",
            controls: source.controls,
            watchedApplicationIDs: source.watchedApplicationIDs
        )
        profiles.append(profile)
        selectedProfileID = profile.id
        activeControls = profile.controls
        return profile
    }

    public mutating func deleteProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }), !profile.isBuiltIn else {
            return
        }
        profiles.removeAll { $0.id == id }
        if selectedProfileID == id {
            selectProfile(id: Self.agentProfileID)
        }
        normalize()
    }

    public mutating func normalize() {
        if !profiles.contains(where: { $0.id == Self.agentProfileID }) {
            profiles.insert(Self.agentMode, at: 0)
        }
        if !profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = Self.agentProfileID
            activeControls = Self.agentMode.controls
        }

        var seen = Set<String>()
        watchedApplications = watchedApplications.filter { application in
            !application.id.isEmpty && seen.insert(application.id).inserted
        }

        let knownApplicationIDs = Set(watchedApplications.map(\.id))
        for index in profiles.indices {
            var profileSeen = Set<String>()
            profiles[index].watchedApplicationIDs = profiles[index].watchedApplicationIDs.filter {
                knownApplicationIDs.contains($0) && profileSeen.insert($0).inserted
            }
        }
    }
}
