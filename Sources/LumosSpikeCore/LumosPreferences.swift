import Foundation

public struct AtomicControlPreferences: Codable, Equatable, Sendable {
    public var preventDisplayIdleSleep: Bool
    public var preventSystemIdleSleep: Bool
    public var requestClamshellProtection: Bool
    public var clamshellMaximumDurationMinutes: Int
    public var clamshellBatteryFloorPercent: Int
    public var preferLowPowerMode: Bool

    public init(
        preventDisplayIdleSleep: Bool,
        preventSystemIdleSleep: Bool,
        requestClamshellProtection: Bool,
        clamshellMaximumDurationMinutes: Int = 120,
        clamshellBatteryFloorPercent: Int = 20,
        preferLowPowerMode: Bool
    ) {
        self.preventDisplayIdleSleep = preventDisplayIdleSleep
        self.preventSystemIdleSleep = preventSystemIdleSleep
        self.requestClamshellProtection = requestClamshellProtection
        self.clamshellMaximumDurationMinutes = clamshellMaximumDurationMinutes
        self.clamshellBatteryFloorPercent = clamshellBatteryFloorPercent
        self.preferLowPowerMode = preferLowPowerMode
        normalize()
    }

    public mutating func normalize() {
        clamshellMaximumDurationMinutes = min(max(clamshellMaximumDurationMinutes, 15), 480)
        clamshellBatteryFloorPercent = min(max(clamshellBatteryFloorPercent, 10), 50)
    }

    private enum CodingKeys: String, CodingKey {
        case preventDisplayIdleSleep
        case preventSystemIdleSleep
        case requestClamshellProtection
        case clamshellMaximumDurationMinutes
        case clamshellBatteryFloorPercent
        case preferLowPowerMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        preventDisplayIdleSleep = try container.decode(Bool.self, forKey: .preventDisplayIdleSleep)
        preventSystemIdleSleep = try container.decode(Bool.self, forKey: .preventSystemIdleSleep)
        requestClamshellProtection = try container.decode(Bool.self, forKey: .requestClamshellProtection)
        clamshellMaximumDurationMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .clamshellMaximumDurationMinutes
        ) ?? 120
        clamshellBatteryFloorPercent = try container.decodeIfPresent(
            Int.self,
            forKey: .clamshellBatteryFloorPercent
        ) ?? 20
        preferLowPowerMode = try container.decode(Bool.self, forKey: .preferLowPowerMode)
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(preventDisplayIdleSleep, forKey: .preventDisplayIdleSleep)
        try container.encode(preventSystemIdleSleep, forKey: .preventSystemIdleSleep)
        try container.encode(requestClamshellProtection, forKey: .requestClamshellProtection)
        try container.encode(clamshellMaximumDurationMinutes, forKey: .clamshellMaximumDurationMinutes)
        try container.encode(clamshellBatteryFloorPercent, forKey: .clamshellBatteryFloorPercent)
        try container.encode(preferLowPowerMode, forKey: .preferLowPowerMode)
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

public struct LumosPreferences: Codable, Equatable, Sendable {
    public static let schemaVersion = 5

    public var version: Int
    public var activeControls: AtomicControlPreferences
    public var watchedApplications: [WatchedApplication]

    public init(
        version: Int = schemaVersion,
        activeControls: AtomicControlPreferences,
        watchedApplications: [WatchedApplication]
    ) {
        self.version = version
        self.activeControls = activeControls
        self.watchedApplications = watchedApplications
        normalize()
    }

    public static var defaultControls: AtomicControlPreferences {
        AtomicControlPreferences(
            preventDisplayIdleSleep: false,
            preventSystemIdleSleep: true,
            requestClamshellProtection: false,
            preferLowPowerMode: true
        )
    }

    public static var defaults: LumosPreferences {
        return LumosPreferences(
            activeControls: defaultControls,
            watchedApplications: []
        )
    }

    public mutating func normalize() {
        version = Self.schemaVersion
        activeControls.normalize()

        var seen = Set<String>()
        watchedApplications = watchedApplications.filter { application in
            !application.id.isEmpty && seen.insert(application.id).inserted
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case activeControls
        case watchedApplications
        case selectedProfileID
        case profiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = Self.schemaVersion
        activeControls = try container.decodeIfPresent(
            AtomicControlPreferences.self,
            forKey: .activeControls
        ) ?? Self.defaultControls
        watchedApplications = try container.decodeIfPresent(
            [WatchedApplication].self,
            forKey: .watchedApplications
        ) ?? []

        if let selectedProfileID = try container.decodeIfPresent(UUID.self, forKey: .selectedProfileID),
           let legacyProfiles = try container.decodeIfPresent(
                [LegacyLumosProfile].self,
                forKey: .profiles
           ),
           let selectedProfile = legacyProfiles.first(where: { $0.id == selectedProfileID }) {
            let selectedApplicationIDs = Set(selectedProfile.watchedApplicationIDs)
            watchedApplications = watchedApplications.filter {
                selectedApplicationIDs.contains($0.id)
            }
        }
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .version)
        try container.encode(activeControls, forKey: .activeControls)
        try container.encode(watchedApplications, forKey: .watchedApplications)
    }
}

private struct LegacyLumosProfile: Decodable {
    let id: UUID
    let watchedApplicationIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case id
        case watchedApplicationIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        watchedApplicationIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .watchedApplicationIDs
        ) ?? []
    }
}
