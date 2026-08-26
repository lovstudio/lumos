import Darwin
import Foundation
import LumosSpikeCore
import Security

private final class LumosPrivilegedPowerService: NSObject, LumosPrivilegedPowerServiceProtocol {
    private let clientPID: pid_t
    private let clientUID: uid_t

    init(clientPID: pid_t, clientUID: uid_t) {
        self.clientPID = clientPID
        self.clientUID = clientUID
    }

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func activateClamshellProtection(
        ownerPID: Int32,
        markerPath: String,
        deadline: Double,
        batteryFloorPercent: Int,
        reply: @escaping (Int32, String?) -> Void
    ) {
        guard ownerPID == clientPID else {
            reply(EPERM, "请求进程与当前 Lumos 实例不一致。")
            return
        }
        guard (10...50).contains(batteryFloorPercent) else {
            reply(EINVAL, "电池安全线超出允许范围。")
            return
        }

        let now = Date().timeIntervalSince1970
        guard deadline > now, deadline <= now + (8 * 60 * 60) + 60 else {
            reply(EINVAL, "合盖运行时长超出允许范围。")
            return
        }
        guard markerPath == expectedMarkerPath(for: clientUID) else {
            reply(EPERM, "安全标记路径无效。")
            return
        }

        let enable = runPMSet(["-a", "disablesleep", "1"])
        guard enable.status == 0 else {
            reply(enable.status, enable.message)
            return
        }

        do {
            try startClamshellWatchdog(
                ownerPID: ownerPID,
                markerPath: markerPath,
                deadline: Int(deadline),
                batteryFloorPercent: batteryFloorPercent
            )
            reply(0, nil)
        } catch {
            _ = runPMSet(["-a", "disablesleep", "0"])
            reply(EIO, "无法启动合盖安全保护：\(error.localizedDescription)")
        }
    }

    func restoreClamshellSleep(reply: @escaping (Int32, String?) -> Void) {
        let result = runPMSet(["-a", "disablesleep", "0"])
        reply(result.status, result.message)
    }

    func setLowPowerMode(
        enabled: Bool,
        powerSource: String,
        reply: @escaping (Int32, String?) -> Void
    ) {
        let sourceFlag: String
        switch powerSource {
        case LowPowerModePowerSource.acPower.rawValue:
            sourceFlag = "-c"
        case LowPowerModePowerSource.battery.rawValue:
            sourceFlag = "-b"
        case LowPowerModePowerSource.ups.rawValue:
            sourceFlag = "-u"
        default:
            reply(EINVAL, "无法识别当前电源来源。")
            return
        }

        let result = runPMSet([sourceFlag, "lowpowermode", enabled ? "1" : "0"])
        reply(result.status, result.message)
    }

    private func startClamshellWatchdog(
        ownerPID: Int32,
        markerPath: String,
        deadline: Int,
        batteryFloorPercent: Int
    ) throws {
        let marker = shellQuote(markerPath)
        let watchdog = [
            "while /bin/kill -0 \(ownerPID) 2>/dev/null && /bin/test -f \(marker)",
            "do",
            "now=$(/bin/date +%s)",
            "[ \"$now\" -ge \(deadline) ] && break",
            "power=$(/usr/bin/pmset -g batt 2>/dev/null)",
            "case \"$power\" in *\"Battery Power\"*) percent=$(printf '%s\\n' \"$power\" | /usr/bin/sed -n 's/.*[[:space:]]\\([0-9][0-9]*\\)%.*/\\1/p' | /usr/bin/head -n 1); [ -n \"$percent\" ] && [ \"$percent\" -le \(batteryFloorPercent) ] && break ;; esac",
            "/bin/sleep 2",
            "done",
            "/usr/bin/pmset -a disablesleep 0",
            "/bin/rm -f \(marker)",
        ].joined(separator: "; ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", watchdog]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func runPMSet(_ arguments: [String]) -> (status: Int32, message: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (
                process.terminationStatus,
                message.isEmpty ? nil : message
            )
        } catch {
            return (EIO, error.localizedDescription)
        }
    }

    private func expectedMarkerPath(for uid: uid_t) -> String? {
        guard let passwordEntry = getpwuid(uid),
              let home = passwordEntry.pointee.pw_dir else { return nil }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Lumos", isDirectory: true)
            .appendingPathComponent("clamshell-session.json")
            .path
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private final class LumosPrivilegedListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let configuration: LumosPrivilegedServiceConfiguration
    private let connectionLock = NSLock()
    private var activeConnectionCount = 0

    init(configuration: LumosPrivilegedServiceConfiguration) {
        self.configuration = configuration
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        guard Self.isTrustedLumosClient(
            pid: newConnection.processIdentifier,
            expectedBundleIdentifier: configuration.hostBundleIdentifier
        ) else {
            return false
        }

        let service = LumosPrivilegedPowerService(
            clientPID: newConnection.processIdentifier,
            clientUID: newConnection.effectiveUserIdentifier
        )
        newConnection.exportedInterface = NSXPCInterface(
            with: LumosPrivilegedPowerServiceProtocol.self
        )
        newConnection.exportedObject = service
        connectionLock.withLock { activeConnectionCount += 1 }
        newConnection.invalidationHandler = { [weak self] in
            self?.connectionDidInvalidate()
        }
        newConnection.resume()
        return true
    }

    private func connectionDidInvalidate() {
        let shouldScheduleExit = connectionLock.withLock { () -> Bool in
            activeConnectionCount = max(0, activeConnectionCount - 1)
            return activeConnectionCount == 0
        }
        guard shouldScheduleExit else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self,
                  self.connectionLock.withLock({ self.activeConnectionCount == 0 })
            else { return }
            exit(EXIT_SUCCESS)
        }
    }

    private static func isTrustedLumosClient(
        pid: pid_t,
        expectedBundleIdentifier: String
    ) -> Bool {
        guard let helperInfo = signingInformation(for: nil),
              let clientInfo = signingInformation(for: pid),
              let helperTeam = helperInfo[kSecCodeInfoTeamIdentifier as String] as? String,
              let clientTeam = clientInfo[kSecCodeInfoTeamIdentifier as String] as? String,
              !helperTeam.isEmpty,
              helperTeam == clientTeam,
              let identifier = clientInfo[kSecCodeInfoIdentifier as String] as? String,
              identifier == expectedBundleIdentifier
        else { return false }
        return true
    }

    private static func signingInformation(for pid: pid_t?) -> [String: Any]? {
        var code: SecCode?
        let status: OSStatus
        if let pid {
            let attributes = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
            status = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        } else {
            status = SecCodeCopySelf([], &code)
        }
        guard status == errSecSuccess, let code else { return nil }
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        let informationFlags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(
            staticCode,
            informationFlags,
            &information
        ) == errSecSuccess else {
            return nil
        }
        return information as? [String: Any]
    }
}

private func requestedConfiguration(
    arguments: [String]
) -> LumosPrivilegedServiceConfiguration? {
    guard let flagIndex = arguments.firstIndex(of: "--mach-service-name"),
          arguments.indices.contains(flagIndex + 1)
    else { return nil }
    return LumosPrivilegedService.configuration(
        forMachServiceName: arguments[flagIndex + 1]
    )
}

guard let configuration = requestedConfiguration(arguments: CommandLine.arguments) else {
    FileHandle.standardError.write(
        Data("Lumos helper requires a recognized --mach-service-name.\n".utf8)
    )
    exit(EX_USAGE)
}

private let delegate = LumosPrivilegedListenerDelegate(configuration: configuration)
private let listener = NSXPCListener(machServiceName: configuration.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
