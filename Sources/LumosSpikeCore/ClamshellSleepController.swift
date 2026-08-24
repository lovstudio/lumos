import AppKit
import Darwin
import Foundation

public enum ClamshellSleepOwnership: String, Codable, Equatable, Sendable {
    case none
    case lumos
    case external
}

public struct ClamshellSleepSnapshot: Codable, Equatable, Sendable {
    public let isAvailable: Bool
    public let isSleepDisabled: Bool
    public let ownership: ClamshellSleepOwnership
    public let detail: String

    public init(
        isAvailable: Bool,
        isSleepDisabled: Bool,
        ownership: ClamshellSleepOwnership,
        detail: String
    ) {
        self.isAvailable = isAvailable
        self.isSleepDisabled = isSleepDisabled
        self.ownership = ownership
        self.detail = detail
    }

    public static let unavailable = ClamshellSleepSnapshot(
        isAvailable: false,
        isSleepDisabled: false,
        ownership: .none,
        detail: "无法读取 macOS 的 SleepDisabled 状态。"
    )
}

public enum ClamshellPrivilegedExecutionResult: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed(String)
}

public enum ClamshellSleepTransitionState: String, Equatable, Sendable {
    case activated
    case deactivated
    case externallyManaged
    case cancelled
    case failed
}

public struct ClamshellSleepTransition: Equatable, Sendable {
    public let state: ClamshellSleepTransitionState
    public let snapshot: ClamshellSleepSnapshot
    public let message: String?

    public init(
        state: ClamshellSleepTransitionState,
        snapshot: ClamshellSleepSnapshot,
        message: String? = nil
    ) {
        self.state = state
        self.snapshot = snapshot
        self.message = message
    }
}

public enum ClamshellSleepOutputParser {
    public static func isSleepDisabled(_ output: String) -> Bool {
        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let fields = rawLine.split(whereSeparator: \Character.isWhitespace)
            guard fields.count >= 2, fields[0].caseInsensitiveCompare("SleepDisabled") == .orderedSame else {
                continue
            }
            return fields[1] == "1" || fields[1].caseInsensitiveCompare("yes") == .orderedSame
        }
        return false
    }
}

/// Controls the system-wide `pmset disablesleep` override used for experimental
/// closed-display sessions. It never clears a setting it did not enable.
///
/// Activation starts a short-lived root watchdog. The watchdog restores normal
/// sleep if Lumos exits, the session reaches its deadline, the battery reaches
/// its configured floor, or Lumos removes its marker during a normal stop.
public final class ClamshellSleepController {
    public typealias StatusReader = () throws -> String
    public typealias PrivilegedExecutor = (String) -> ClamshellPrivilegedExecutionResult
    public typealias Clock = () -> Date
    public typealias Sleeper = (TimeInterval) -> Void

    private struct SessionMarker: Codable {
        let ownerPID: Int32
        let startedAt: Date
        let deadline: Date
        let batteryFloorPercent: Int
    }

    private let markerURL: URL
    private let processIdentifier: Int32
    private let statusReader: StatusReader
    private let privilegedExecutor: PrivilegedExecutor
    private let clock: Clock
    private let sleeper: Sleeper
    private let fileManager: FileManager

    public convenience init() {
        self.init(
            markerURL: Self.defaultMarkerURL,
            processIdentifier: getpid(),
            statusReader: Self.readSystemStatus,
            privilegedExecutor: Self.executeWithAdministratorPrivileges,
            clock: Date.init,
            sleeper: Thread.sleep(forTimeInterval:),
            fileManager: .default
        )
    }

    public init(
        markerURL: URL,
        processIdentifier: Int32,
        statusReader: @escaping StatusReader,
        privilegedExecutor: @escaping PrivilegedExecutor,
        clock: @escaping Clock = Date.init,
        sleeper: @escaping Sleeper = Thread.sleep(forTimeInterval:),
        fileManager: FileManager = .default
    ) {
        self.markerURL = markerURL
        self.processIdentifier = processIdentifier
        self.statusReader = statusReader
        self.privilegedExecutor = privilegedExecutor
        self.clock = clock
        self.sleeper = sleeper
        self.fileManager = fileManager
    }

    public func snapshot() -> ClamshellSleepSnapshot {
        do {
            let disabled = ClamshellSleepOutputParser.isSleepDisabled(try statusReader())
            let marker = readMarker()
            let ownership: ClamshellSleepOwnership
            if disabled, marker?.ownerPID == processIdentifier {
                ownership = .lumos
            } else if disabled {
                ownership = .external
            } else {
                ownership = .none
            }

            let detail = switch ownership {
            case .lumos: "合盖休眠已由 Lumos 暂时关闭。"
            case .external: "系统休眠已由其他工具或设置关闭。"
            case .none: "合盖时仍会按 macOS 默认策略休眠。"
            }
            return ClamshellSleepSnapshot(
                isAvailable: true,
                isSleepDisabled: disabled,
                ownership: ownership,
                detail: detail
            )
        } catch {
            return ClamshellSleepSnapshot(
                isAvailable: false,
                isSleepDisabled: false,
                ownership: .none,
                detail: "读取 SleepDisabled 失败：\(error)"
            )
        }
    }

    @discardableResult
    public func reconcileStaleSession() -> ClamshellSleepSnapshot {
        guard let marker = readMarker(), marker.ownerPID != processIdentifier else {
            return snapshot()
        }

        try? fileManager.removeItem(at: markerURL)
        return waitForExpectedState(false, timeout: 3)
    }

    public func activate(
        maximumDurationMinutes: Int,
        batteryFloorPercent: Int
    ) -> ClamshellSleepTransition {
        let before = snapshot()
        guard before.isAvailable else {
            return ClamshellSleepTransition(
                state: .failed,
                snapshot: before,
                message: before.detail
            )
        }
        if before.isSleepDisabled {
            return ClamshellSleepTransition(
                state: before.ownership == .lumos ? .activated : .externallyManaged,
                snapshot: before,
                message: before.ownership == .external
                    ? "SleepDisabled 已由其他工具开启；Lumos 不会接管或在退出时关闭它。"
                    : nil
            )
        }

        let duration = min(max(maximumDurationMinutes, 15), 480)
        let floor = min(max(batteryFloorPercent, 10), 50)
        let startedAt = clock()
        let marker = SessionMarker(
            ownerPID: processIdentifier,
            startedAt: startedAt,
            deadline: startedAt.addingTimeInterval(TimeInterval(duration * 60)),
            batteryFloorPercent: floor
        )

        do {
            try fileManager.createDirectory(
                at: markerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(marker).write(to: markerURL, options: .atomic)
        } catch {
            let current = snapshot()
            return ClamshellSleepTransition(
                state: .failed,
                snapshot: current,
                message: "无法创建合盖守护标记：\(error)"
            )
        }

        let command = privilegedActivationCommand(for: marker)
        switch privilegedExecutor(command) {
        case .cancelled:
            try? fileManager.removeItem(at: markerURL)
            return ClamshellSleepTransition(
                state: .cancelled,
                snapshot: snapshot(),
                message: "已取消管理员授权，合盖模式没有启用。"
            )
        case .failed(let message):
            try? fileManager.removeItem(at: markerURL)
            return ClamshellSleepTransition(
                state: .failed,
                snapshot: snapshot(),
                message: message
            )
        case .succeeded:
            break
        }

        let after = waitForExpectedState(true, timeout: 2)
        guard after.isSleepDisabled else {
            try? fileManager.removeItem(at: markerURL)
            return ClamshellSleepTransition(
                state: .failed,
                snapshot: after,
                message: "管理员命令已返回，但系统没有回读到 SleepDisabled=1。"
            )
        }
        return ClamshellSleepTransition(state: .activated, snapshot: after)
    }

    public func deactivate() -> ClamshellSleepTransition {
        let before = snapshot()
        guard before.ownership == .lumos else {
            return ClamshellSleepTransition(
                state: before.ownership == .external ? .externallyManaged : .deactivated,
                snapshot: before,
                message: before.ownership == .external
                    ? "SleepDisabled 由其他工具管理，Lumos 未修改该系统设置。"
                    : nil
            )
        }

        do {
            try fileManager.removeItem(at: markerURL)
        } catch {
            return ClamshellSleepTransition(
                state: .failed,
                snapshot: before,
                message: "无法通知安全 watchdog 恢复系统休眠：\(error)"
            )
        }

        let after = waitForExpectedState(false, timeout: 4)
        guard !after.isSleepDisabled else {
            return ClamshellSleepTransition(
                state: .failed,
                snapshot: after,
                message: "安全 watchdog 尚未恢复系统休眠。可运行 sudo pmset -a disablesleep 0 手动恢复。"
            )
        }
        return ClamshellSleepTransition(state: .deactivated, snapshot: after)
    }

    private func waitForExpectedState(
        _ expected: Bool,
        timeout: TimeInterval
    ) -> ClamshellSleepSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var current = snapshot()
        while current.isAvailable,
              current.isSleepDisabled != expected,
              Date() < deadline {
            sleeper(0.1)
            current = snapshot()
        }
        return current
    }

    private func readMarker() -> SessionMarker? {
        guard let data = try? Data(contentsOf: markerURL) else { return nil }
        return try? JSONDecoder().decode(SessionMarker.self, from: data)
    }

    private func privilegedActivationCommand(for marker: SessionMarker) -> String {
        let markerPath = Self.shellQuote(markerURL.path)
        let deadline = Int(marker.deadline.timeIntervalSince1970)
        let watchdog = [
            "while /bin/kill -0 \(marker.ownerPID) 2>/dev/null && /bin/test -f \(markerPath)",
            "do",
            "now=$(/bin/date +%s)",
            "[ \"$now\" -ge \(deadline) ] && break",
            "power=$(/usr/bin/pmset -g batt 2>/dev/null)",
            "case \"$power\" in *\"Battery Power\"*) percent=$(printf '%s\\n' \"$power\" | /usr/bin/sed -n 's/.*[[:space:]]\\([0-9][0-9]*\\)%.*/\\1/p' | /usr/bin/head -n 1); [ -n \"$percent\" ] && [ \"$percent\" -le \(marker.batteryFloorPercent) ] && break ;; esac",
            "/bin/sleep 2",
            "done",
            "/usr/bin/pmset -a disablesleep 0",
            "/bin/rm -f \(markerPath)",
        ].joined(separator: "; ")

        return [
            "/usr/bin/pmset -a disablesleep 1 || exit $?",
            "/usr/bin/nohup /bin/sh -c \(Self.shellQuote(watchdog)) </dev/null >/dev/null 2>&1 &",
        ].joined(separator: "; ")
    }

    private static var defaultMarkerURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("Lumos", isDirectory: true)
            .appendingPathComponent("clamshell-session.json")
    }

    private static func readSystemStatus() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ClamshellSleepControllerError.commandFailed(
                String(decoding: errorData, as: UTF8.self)
            )
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    private static func executeWithAdministratorPrivileges(
        _ command: String
    ) -> ClamshellPrivilegedExecutionResult {
        let source = "do shell script \(appleScriptLiteral(command)) with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            return .failed("无法创建管理员授权请求。")
        }

        var errorInfo: NSDictionary?
        _ = script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .succeeded }

        let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
        if code == -128 {
            return .cancelled
        }
        let message = errorInfo[NSAppleScript.errorMessage] as? String
            ?? "macOS 拒绝了系统休眠设置变更。"
        return .failed(message)
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

public enum ClamshellSleepControllerError: Error, CustomStringConvertible {
    case commandFailed(String)

    public var description: String {
        switch self {
        case .commandFailed(let message):
            message.isEmpty ? "pmset 状态读取失败。" : message
        }
    }
}
