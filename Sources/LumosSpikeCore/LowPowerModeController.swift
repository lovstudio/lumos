import Foundation

public enum LowPowerModePowerSource: String, Codable, Equatable, Sendable {
    case acPower
    case battery
    case ups
    case unknown
}

public struct LowPowerModeSnapshot: Codable, Equatable, Sendable {
    public let isAvailable: Bool
    public let isEnabled: Bool
    public let powerSource: LowPowerModePowerSource
    public let detail: String

    public init(
        isAvailable: Bool,
        isEnabled: Bool,
        powerSource: LowPowerModePowerSource,
        detail: String
    ) {
        self.isAvailable = isAvailable
        self.isEnabled = isEnabled
        self.powerSource = powerSource
        self.detail = detail
    }
}

public enum LowPowerModeTransitionState: String, Equatable, Sendable {
    case updated
    case unchanged
    case cancelled
    case failed
}

public struct LowPowerModeTransition: Equatable, Sendable {
    public let state: LowPowerModeTransitionState
    public let snapshot: LowPowerModeSnapshot
    public let message: String?

    public init(
        state: LowPowerModeTransitionState,
        snapshot: LowPowerModeSnapshot,
        message: String? = nil
    ) {
        self.state = state
        self.snapshot = snapshot
        self.message = message
    }
}

public enum LowPowerModeOutputParser {
    public static func isEnabled(_ output: String) -> Bool? {
        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let fields = rawLine.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2,
                  fields[0].caseInsensitiveCompare("lowpowermode") == .orderedSame
            else { continue }
            return fields[1] == "1"
        }
        return nil
    }

    public static func powerSource(_ output: String) -> LowPowerModePowerSource {
        if output.localizedCaseInsensitiveContains("Battery Power") {
            return .battery
        }
        if output.localizedCaseInsensitiveContains("AC Power") {
            return .acPower
        }
        if output.localizedCaseInsensitiveContains("UPS Power") {
            return .ups
        }
        return .unknown
    }
}

/// Controls Low Power Mode for the power source currently in use, preserving
/// the user's separate Battery and AC policies.
public final class LowPowerModeController {
    public typealias StatusReader = () throws -> (settings: String, battery: String)
    public typealias PrivilegedExecutor = (String) -> PrivilegedCommandResult
    public typealias Sleeper = (TimeInterval) -> Void

    private let statusReader: StatusReader
    private let privilegedExecutor: PrivilegedExecutor
    private let usesSharedPrivilegedRuntime: Bool
    private let sleeper: Sleeper

    public convenience init() {
        self.init(
            statusReader: Self.readSystemStatus,
            privilegedExecutor: PrivilegedCommandExecutor.execute,
            usesSharedPrivilegedRuntime: true,
            sleeper: Thread.sleep(forTimeInterval:)
        )
    }

    public init(
        statusReader: @escaping StatusReader,
        privilegedExecutor: @escaping PrivilegedExecutor,
        usesSharedPrivilegedRuntime: Bool = false,
        sleeper: @escaping Sleeper = Thread.sleep(forTimeInterval:)
    ) {
        self.statusReader = statusReader
        self.privilegedExecutor = privilegedExecutor
        self.usesSharedPrivilegedRuntime = usesSharedPrivilegedRuntime
        self.sleeper = sleeper
    }

    public func snapshot() -> LowPowerModeSnapshot {
        do {
            let output = try statusReader()
            let source = LowPowerModeOutputParser.powerSource(output.battery)
            guard let enabled = LowPowerModeOutputParser.isEnabled(output.settings),
                  source != .unknown else {
                return unavailableSnapshot("macOS 没有返回当前电源来源的低功耗状态。")
            }
            let sourceLabel = switch source {
            case .acPower: "接通电源时"
            case .battery: "使用电池时"
            case .ups: "使用 UPS 时"
            case .unknown: "当前"
            }
            return LowPowerModeSnapshot(
                isAvailable: true,
                isEnabled: enabled,
                powerSource: source,
                detail: "\(sourceLabel)低功耗已\(enabled ? "开启" : "关闭")"
            )
        } catch {
            return unavailableSnapshot("读取低功耗模式失败：\(error)")
        }
    }

    public func setEnabled(_ enabled: Bool) -> LowPowerModeTransition {
        let before = snapshot()
        guard before.isAvailable else {
            return LowPowerModeTransition(state: .failed, snapshot: before, message: before.detail)
        }
        guard before.isEnabled != enabled else {
            return LowPowerModeTransition(state: .unchanged, snapshot: before)
        }

        let sourceFlag = switch before.powerSource {
        case .acPower: "-c"
        case .battery: "-b"
        case .ups: "-u"
        case .unknown: ""
        }
        guard !sourceFlag.isEmpty else {
            return LowPowerModeTransition(
                state: .failed,
                snapshot: before,
                message: "无法识别当前电源来源。"
            )
        }

        let command = "/usr/bin/pmset \(sourceFlag) lowpowermode \(enabled ? 1 : 0)"
        let updateResult = usesSharedPrivilegedRuntime
            ? PrivilegedPowerRuntime.shared.setLowPowerMode(
                enabled,
                powerSource: before.powerSource,
                legacyCommand: command
            )
            : privilegedExecutor(command)
        switch updateResult {
        case .cancelled:
            return LowPowerModeTransition(
                state: .cancelled,
                snapshot: snapshot(),
                message: "已取消管理员授权，低功耗模式没有改变。"
            )
        case .failed(let message):
            return LowPowerModeTransition(state: .failed, snapshot: snapshot(), message: message)
        case .succeeded:
            break
        }

        let after = waitForExpectedState(enabled, timeout: 2)
        guard after.isEnabled == enabled else {
            return LowPowerModeTransition(
                state: .failed,
                snapshot: after,
                message: "管理员命令已返回，但系统低功耗状态没有按预期改变。"
            )
        }
        return LowPowerModeTransition(state: .updated, snapshot: after)
    }

    private func waitForExpectedState(
        _ expected: Bool,
        timeout: TimeInterval
    ) -> LowPowerModeSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var current = snapshot()
        while current.isAvailable, current.isEnabled != expected, Date() < deadline {
            sleeper(0.1)
            current = snapshot()
        }
        return current
    }

    private func unavailableSnapshot(_ detail: String) -> LowPowerModeSnapshot {
        LowPowerModeSnapshot(
            isAvailable: false,
            isEnabled: false,
            powerSource: .unknown,
            detail: detail
        )
    }

    private static func readSystemStatus() throws -> (settings: String, battery: String) {
        (
            settings: try runPMSet(arguments: ["-g"]),
            battery: try runPMSet(arguments: ["-g", "batt"])
        )
    }

    private static func runPMSet(arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LowPowerModeControllerError.commandFailed(String(decoding: errorData, as: UTF8.self))
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}

public enum LowPowerModeControllerError: Error, CustomStringConvertible {
    case commandFailed(String)

    public var description: String {
        switch self {
        case .commandFailed(let message):
            message.isEmpty ? "pmset 状态读取失败。" : message
        }
    }
}
