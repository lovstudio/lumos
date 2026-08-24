import Foundation
import Network

public struct NetworkPathSnapshot: Codable, Equatable, Sendable {
    public let status: String
    public let isExpensive: Bool
    public let isConstrained: Bool
    public let supportsIPv4: Bool
    public let supportsIPv6: Bool
    public let supportsDNS: Bool
    public let interfaces: [String]
}

private final class NetworkSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: NetworkPathSnapshot?

    func set(_ newValue: NetworkPathSnapshot) {
        lock.withLock { value = newValue }
    }

    func get() -> NetworkPathSnapshot? {
        lock.withLock { value }
    }
}

public enum NetworkProbe {
    public static func currentPath(timeout: TimeInterval = 3) -> NetworkPathSnapshot? {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "ai.lovstudio.lumos.spike.network")
        let semaphore = DispatchSemaphore(value: 0)
        let box = NetworkSnapshotBox()

        monitor.pathUpdateHandler = { path in
            box.set(snapshot(path))
            semaphore.signal()
        }
        monitor.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)
        monitor.cancel()
        return box.get()
    }

    private static func snapshot(_ path: NWPath) -> NetworkPathSnapshot {
        let status: String = switch path.status {
        case .satisfied: "satisfied"
        case .requiresConnection: "requiresConnection"
        case .unsatisfied: "unsatisfied"
        @unknown default: "unknown"
        }

        return NetworkPathSnapshot(
            status: status,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            supportsDNS: path.supportsDNS,
            interfaces: Array(Set(path.availableInterfaces.map { "\($0.type):\($0.name)" }))
                .sorted()
        )
    }
}
