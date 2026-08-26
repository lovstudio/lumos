import Foundation

public struct LumosPrivilegedServiceConfiguration: Equatable, Sendable {
    public let hostBundleIdentifier: String
    public let machServiceName: String
    public let daemonPlistName: String

    public init(
        hostBundleIdentifier: String,
        machServiceName: String,
        daemonPlistName: String
    ) {
        self.hostBundleIdentifier = hostBundleIdentifier
        self.machServiceName = machServiceName
        self.daemonPlistName = daemonPlistName
    }
}

public enum LumosPrivilegedService {
    public static let production = LumosPrivilegedServiceConfiguration(
        hostBundleIdentifier: "ai.lovstudio.lumos",
        machServiceName: "ai.lovstudio.lumos.power-helper",
        daemonPlistName: "ai.lovstudio.lumos.power-helper.plist"
    )

    public static let development = LumosPrivilegedServiceConfiguration(
        hostBundleIdentifier: "ai.lovstudio.lumos.dev",
        machServiceName: "ai.lovstudio.lumos.dev.power-helper",
        daemonPlistName: "ai.lovstudio.lumos.dev.power-helper.plist"
    )

    public static let allConfigurations = [production, development]

    public static func configuration(
        forHostBundleIdentifier bundleIdentifier: String?
    ) -> LumosPrivilegedServiceConfiguration? {
        allConfigurations.first { $0.hostBundleIdentifier == bundleIdentifier }
    }

    public static func configuration(
        forMachServiceName machServiceName: String?
    ) -> LumosPrivilegedServiceConfiguration? {
        allConfigurations.first { $0.machServiceName == machServiceName }
    }
}

@objc public protocol LumosPrivilegedPowerServiceProtocol {
    func ping(reply: @escaping (Bool) -> Void)

    func activateClamshellProtection(
        ownerPID: Int32,
        markerPath: String,
        deadline: Double,
        batteryFloorPercent: Int,
        reply: @escaping (Int32, String?) -> Void
    )

    func restoreClamshellSleep(reply: @escaping (Int32, String?) -> Void)

    func setLowPowerMode(
        enabled: Bool,
        powerSource: String,
        reply: @escaping (Int32, String?) -> Void
    )
}

public enum PrivilegedHelperUnavailableReason: Equatable, Sendable {
    case approvalRequired
    case incompleteInstallation
    case registrationFailed(String)
    case unknownStatus

    public var message: String {
        switch self {
        case .approvalRequired:
            "请先在“系统设置 > 通用 > 登录项与扩展”中允许 Lumos。"
        case .incompleteInstallation:
            "Lumos 系统辅助程序不完整，请重新安装。"
        case .registrationFailed(let detail):
            "系统控制初始化失败：\(detail)"
        case .unknownStatus:
            "无法确认 Lumos 系统辅助程序状态。"
        }
    }
}

public enum PrivilegedPowerRuntimeMode: Equatable, Sendable {
    case legacyAuthorization
    case helper(LumosPrivilegedServiceConfiguration)
    case helperUnavailable(PrivilegedHelperUnavailableReason)
}

/// Process-wide routing between the signed privileged helper used by bundled
/// apps and the AppleScript authorization fallback used by `swift run`.
public final class PrivilegedPowerRuntime: @unchecked Sendable {
    public static let shared = PrivilegedPowerRuntime()

    private let lock = NSLock()
    private var storedMode: PrivilegedPowerRuntimeMode = .legacyAuthorization

    private init() {}

    public var mode: PrivilegedPowerRuntimeMode {
        lock.withLock { storedMode }
    }

    public func configure(_ mode: PrivilegedPowerRuntimeMode) {
        lock.withLock { storedMode = mode }
    }

    public func activateClamshellProtection(
        ownerPID: Int32,
        markerPath: String,
        deadline: Date,
        batteryFloorPercent: Int,
        legacyCommand: @autoclosure () -> String
    ) -> PrivilegedCommandResult {
        switch mode {
        case .legacyAuthorization:
            return PrivilegedCommandExecutor.execute(legacyCommand())
        case .helper(let configuration):
            return PrivilegedPowerServiceClient.shared.activateClamshellProtection(
                configuration: configuration,
                ownerPID: ownerPID,
                markerPath: markerPath,
                deadline: deadline,
                batteryFloorPercent: batteryFloorPercent
            )
        case .helperUnavailable(let reason):
            return .failed(reason.message)
        }
    }

    public func restoreClamshellSleep(
        legacyCommand: @autoclosure () -> String
    ) -> PrivilegedCommandResult {
        switch mode {
        case .legacyAuthorization:
            return PrivilegedCommandExecutor.execute(legacyCommand())
        case .helper(let configuration):
            return PrivilegedPowerServiceClient.shared.restoreClamshellSleep(
                configuration: configuration
            )
        case .helperUnavailable(let reason):
            return .failed(reason.message)
        }
    }

    public func setLowPowerMode(
        _ enabled: Bool,
        powerSource: LowPowerModePowerSource,
        legacyCommand: @autoclosure () -> String
    ) -> PrivilegedCommandResult {
        switch mode {
        case .legacyAuthorization:
            return PrivilegedCommandExecutor.execute(legacyCommand())
        case .helper(let configuration):
            return PrivilegedPowerServiceClient.shared.setLowPowerMode(
                enabled,
                configuration: configuration,
                powerSource: powerSource
            )
        case .helperUnavailable(let reason):
            return .failed(reason.message)
        }
    }
}

private final class PrivilegedReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: PrivilegedCommandResult?

    func store(status: Int32, message: String?) {
        lock.withLock {
            result = status == 0
                ? .succeeded
                : .failed(message ?? "系统辅助程序执行失败（\(status)）。")
        }
    }

    func load() -> PrivilegedCommandResult? {
        lock.withLock { result }
    }
}

public final class PrivilegedPowerServiceClient: @unchecked Sendable {
    public static let shared = PrivilegedPowerServiceClient()

    private let lock = NSLock()
    private var connection: NSXPCConnection?

    private init() {}

    public func invalidate() {
        let previous = lock.withLock { () -> NSXPCConnection? in
            defer { connection = nil }
            return connection
        }
        previous?.invalidate()
    }

    public func ping(timeout: TimeInterval = 2) -> Bool {
        guard let configuration = LumosPrivilegedService.configuration(
            forHostBundleIdentifier: Bundle.main.bundleIdentifier
        ) else { return false }
        return ping(configuration: configuration, timeout: timeout)
    }

    public func ping(
        configuration: LumosPrivilegedServiceConfiguration,
        timeout: TimeInterval = 2
    ) -> Bool {
        pingResult(configuration: configuration, timeout: timeout) == .succeeded
    }

    public func pingResult(
        configuration: LumosPrivilegedServiceConfiguration,
        timeout: TimeInterval = 2
    ) -> PrivilegedCommandResult {
        let semaphore = DispatchSemaphore(value: 0)
        let box = PrivilegedReplyBox()
        guard let proxy = proxy(
            configuration: configuration,
            errorHandler: { error in
                box.store(
                    status: -1,
                    message: "无法连接系统辅助程序：\(error.localizedDescription)"
                )
                semaphore.signal()
            }
        ) else {
            return .failed("系统辅助程序尚未可用。")
        }
        proxy.ping {
            box.store(status: $0 ? 0 : -1, message: $0 ? nil : "系统辅助程序拒绝响应。")
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            invalidate()
            return .failed("系统辅助程序响应超时。")
        }
        return box.load() ?? .failed("系统辅助程序没有返回结果。")
    }

    public func activateClamshellProtection(
        configuration: LumosPrivilegedServiceConfiguration,
        ownerPID: Int32,
        markerPath: String,
        deadline: Date,
        batteryFloorPercent: Int
    ) -> PrivilegedCommandResult {
        call(configuration: configuration) { proxy, reply in
            proxy.activateClamshellProtection(
                ownerPID: ownerPID,
                markerPath: markerPath,
                deadline: deadline.timeIntervalSince1970,
                batteryFloorPercent: batteryFloorPercent,
                reply: reply
            )
        }
    }

    public func restoreClamshellSleep(
        configuration: LumosPrivilegedServiceConfiguration
    ) -> PrivilegedCommandResult {
        call(configuration: configuration) { proxy, reply in
            proxy.restoreClamshellSleep(reply: reply)
        }
    }

    public func setLowPowerMode(
        _ enabled: Bool,
        configuration: LumosPrivilegedServiceConfiguration,
        powerSource: LowPowerModePowerSource
    ) -> PrivilegedCommandResult {
        call(configuration: configuration) { proxy, reply in
            proxy.setLowPowerMode(
                enabled: enabled,
                powerSource: powerSource.rawValue,
                reply: reply
            )
        }
    }

    private func call(
        configuration: LumosPrivilegedServiceConfiguration,
        timeout: TimeInterval = 8,
        _ operation: (
            LumosPrivilegedPowerServiceProtocol,
            @escaping (Int32, String?) -> Void
        ) -> Void
    ) -> PrivilegedCommandResult {
        let semaphore = DispatchSemaphore(value: 0)
        let box = PrivilegedReplyBox()
        guard let proxy = proxy(configuration: configuration, errorHandler: { error in
            box.store(status: -1, message: "无法连接系统辅助程序：\(error.localizedDescription)")
            semaphore.signal()
        }) else {
            return .failed("系统辅助程序尚未可用。")
        }

        operation(proxy) { status, message in
            box.store(status: status, message: message)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            invalidate()
            return .failed("系统辅助程序响应超时。")
        }
        return box.load() ?? .failed("系统辅助程序没有返回结果。")
    }

    private func proxy(
        configuration: LumosPrivilegedServiceConfiguration,
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> LumosPrivilegedPowerServiceProtocol? {
        let activeConnection = lock.withLock { () -> NSXPCConnection in
            if let connection { return connection }

            let created = NSXPCConnection(
                machServiceName: configuration.machServiceName,
                options: .privileged
            )
            created.remoteObjectInterface = NSXPCInterface(
                with: LumosPrivilegedPowerServiceProtocol.self
            )
            created.invalidationHandler = { [weak self] in
                self?.lock.withLock { self?.connection = nil }
            }
            created.interruptionHandler = { [weak self] in
                self?.lock.withLock { self?.connection = nil }
            }
            created.resume()
            connection = created
            return created
        }

        return activeConnection.remoteObjectProxyWithErrorHandler(errorHandler)
            as? LumosPrivilegedPowerServiceProtocol
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func set(_ value: Value) {
        lock.withLock { self.value = value }
    }

    func get() -> Value {
        lock.withLock { value }
    }
}
