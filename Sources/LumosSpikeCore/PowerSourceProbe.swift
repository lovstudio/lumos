import Foundation
import IOKit.ps

public enum PowerSourceKind: String, Codable, Equatable, Sendable {
    case acPower
    case battery
    case ups
    case unknown
}

public struct PowerSourceSnapshot: Codable, Equatable, Sendable {
    public let isAvailable: Bool
    public let kind: PowerSourceKind
    public let batteryLevelPercent: Int?
    public let isCharging: Bool?
    public let detail: String

    public init(
        isAvailable: Bool,
        kind: PowerSourceKind,
        batteryLevelPercent: Int?,
        isCharging: Bool?,
        detail: String
    ) {
        self.isAvailable = isAvailable
        self.kind = kind
        self.batteryLevelPercent = batteryLevelPercent
        self.isCharging = isCharging
        self.detail = detail
    }

    public static let unavailable = PowerSourceSnapshot(
        isAvailable: false,
        kind: .unknown,
        batteryLevelPercent: nil,
        isCharging: nil,
        detail: "无法读取电源与电池状态"
    )
}

public enum PowerSourceSnapshotBuilder {
    public static func build(
        providingSource: String?,
        currentCapacity: Int?,
        maximumCapacity: Int?,
        isCharging: Bool?
    ) -> PowerSourceSnapshot {
        let kind = sourceKind(providingSource)
        let batteryLevel = batteryPercentage(
            currentCapacity: currentCapacity,
            maximumCapacity: maximumCapacity
        )
        let sourceLabel = switch kind {
        case .acPower: "接通电源"
        case .battery: "电池供电"
        case .ups: "UPS 供电"
        case .unknown: "电源来源未知"
        }
        let batteryLabel = batteryLevel.map { " · 电池 \($0)%" } ?? ""

        return PowerSourceSnapshot(
            isAvailable: kind != .unknown,
            kind: kind,
            batteryLevelPercent: batteryLevel,
            isCharging: isCharging,
            detail: sourceLabel + batteryLabel
        )
    }

    public static func sourceKind(_ value: String?) -> PowerSourceKind {
        guard let value else { return .unknown }
        if value.localizedCaseInsensitiveContains("Battery") {
            return .battery
        }
        if value.localizedCaseInsensitiveContains("AC Power") {
            return .acPower
        }
        if value.localizedCaseInsensitiveContains("UPS") {
            return .ups
        }
        return .unknown
    }

    public static func batteryPercentage(
        currentCapacity: Int?,
        maximumCapacity: Int?
    ) -> Int? {
        guard let currentCapacity,
              let maximumCapacity,
              maximumCapacity > 0 else {
            return nil
        }
        let percentage = Int(
            (Double(currentCapacity) / Double(maximumCapacity) * 100).rounded()
        )
        return min(max(percentage, 0), 100)
    }
}

public enum PowerSourceProbe {
    public static func snapshot() -> PowerSourceSnapshot {
        guard let infoReference = IOPSCopyPowerSourcesInfo() else {
            return .unavailable
        }
        let info = infoReference.takeRetainedValue()
        let providingSource = IOPSGetProvidingPowerSourceType(info)?
            .takeUnretainedValue() as String?

        guard let listReference = IOPSCopyPowerSourcesList(info) else {
            return PowerSourceSnapshotBuilder.build(
                providingSource: providingSource,
                currentCapacity: nil,
                maximumCapacity: nil,
                isCharging: nil
            )
        }

        let sources = listReference.takeRetainedValue() as Array
        var currentCapacity: Int?
        var maximumCapacity: Int?
        var isCharging: Bool?

        for source in sources {
            guard let descriptionReference = IOPSGetPowerSourceDescription(info, source) else {
                continue
            }
            let description = descriptionReference.takeUnretainedValue() as NSDictionary
            guard description["Type"] as? String == "InternalBattery" else { continue }

            currentCapacity = description["Current Capacity"] as? Int
            maximumCapacity = description["Max Capacity"] as? Int
            isCharging = description["Is Charging"] as? Bool
            break
        }

        return PowerSourceSnapshotBuilder.build(
            providingSource: providingSource,
            currentCapacity: currentCapacity,
            maximumCapacity: maximumCapacity,
            isCharging: isCharging
        )
    }
}
