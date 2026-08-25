import Foundation

public enum LumosPrivilegedService {
    public static let machServiceName = "ai.lovstudio.lumos.privileged-helper"
    public static let daemonPlistName = "ai.lovstudio.lumos.privileged-helper.plist"
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

public enum PrivilegedPowerRuntimeMode: Equatable, Sendable {
    case legacyAuthorization
    case helper
    case helperUnavailable(String)
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
        case .helper:
            return PrivilegedPowerServiceClient.shared.activateClamshellProtection(
                ownerPID: ownerPID,
                markerPath: markerPath,
                deadline: deadline,
                batteryFloorPercent: batteryFloorPercent
            )
        case .helperUnavailable(let message):
            return .failed(message)
        }
    }

    public func restoreClamshellSleep(
        legacyCommand: @autoclosure () -> String
    ) -> PrivilegedCommandResult {
        switch mode {
        case .legacyAuthorization:
            return PrivilegedCommandExecutor.execute(legacyCommand())
        case .helper:
            return PrivilegedPowerServiceClient.shared.restoreClamshellSleep()
        case .helperUnavailable(let message):
            return .failed(message)
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
        case .helper:
            return PrivilegedPowerServiceClient.shared.setLowPowerMode(
                enabled,
                powerSource: powerSource
            )
        case .helperUnavailable(let message):
            return .failed(message)
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
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedValue(false)
        guard let proxy = proxy(errorHandler: { _ in semaphore.signal() }) else {
            return false
        }
        proxy.ping {
            result.set($0)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return false }
        return result.get()
    }

    public func activateClamshellProtection(
        ownerPID: Int32,
        markerPath: String,
        deadline: Date,
        batteryFloorPercent: Int
    ) -> PrivilegedCommandResult {
        call { proxy, reply in
            proxy.activateClamshellProtection(
                ownerPID: ownerPID,
                markerPath: markerPath,
                deadline: deadline.timeIntervalSince1970,
                batteryFloorPercent: batteryFloorPercent,
                reply: reply
            )
        }
    }

    public func restoreClamshellSleep() -> PrivilegedCommandResult {
        call { proxy, reply in
            proxy.restoreClamshellSleep(reply: reply)
        }
    }

    public func setLowPowerMode(
        _ enabled: Bool,
        powerSource: LowPowerModePowerSource
    ) -> PrivilegedCommandResult {
        call { proxy, reply in
            proxy.setLowPowerMode(
                enabled: enabled,
                powerSource: powerSource.rawValue,
                reply: reply
            )
        }
    }

    private func call(
        timeout: TimeInterval = 8,
        _ operation: (
            LumosPrivilegedPowerServiceProtocol,
            @escaping (Int32, String?) -> Void
        ) -> Void
    ) -> PrivilegedCommandResult {
        let semaphore = DispatchSemaphore(value: 0)
        let box = PrivilegedReplyBox()
        guard let proxy = proxy(errorHandler: { error in
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
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> LumosPrivilegedPowerServiceProtocol? {
        let activeConnection = lock.withLock { () -> NSXPCConnection in
            if let connection { return connection }

            let created = NSXPCConnection(
                machServiceName: LumosPrivilegedService.machServiceName,
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
