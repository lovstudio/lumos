import Foundation

public enum ThermalStateLabel: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown

    init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .unknown
        }
    }
}

public struct SystemStateSnapshot: Codable, Equatable, Sendable {
    public let lowPowerModeEnabled: Bool
    public let thermalState: ThermalStateLabel
    public let operatingSystemVersion: String
    public let processorCount: Int
    public let activeProcessorCount: Int
    public let physicalMemoryBytes: UInt64

    public init(
        lowPowerModeEnabled: Bool,
        thermalState: ThermalStateLabel,
        operatingSystemVersion: String,
        processorCount: Int,
        activeProcessorCount: Int,
        physicalMemoryBytes: UInt64
    ) {
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.thermalState = thermalState
        self.operatingSystemVersion = operatingSystemVersion
        self.processorCount = processorCount
        self.activeProcessorCount = activeProcessorCount
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

public enum SystemStateProbe {
    public static func snapshot(processInfo: ProcessInfo = .processInfo) -> SystemStateSnapshot {
        SystemStateSnapshot(
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermalState: ThermalStateLabel(processInfo.thermalState),
            operatingSystemVersion: processInfo.operatingSystemVersionString,
            processorCount: processInfo.processorCount,
            activeProcessorCount: processInfo.activeProcessorCount,
            physicalMemoryBytes: processInfo.physicalMemory
        )
    }
}
