import AppKit
import Darwin
import Foundation

public struct RunningApplicationSnapshot: Codable, Equatable, Sendable {
    public let pid: pid_t
    public let localizedName: String?
    public let bundleIdentifier: String?
    public let executablePath: String?
    public let isActive: Bool
    public let isHidden: Bool
    public let ownsMenuBar: Bool
}

public struct ProcessIdentity: Codable, CustomStringConvertible, Equatable, Hashable, Sendable {
    public let pid: pid_t
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init(pid: pid_t, startTimeSeconds: UInt64, startTimeMicroseconds: UInt64 = 0) {
        self.pid = pid
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }

    public var description: String {
        "\(pid):\(startTimeSeconds):\(startTimeMicroseconds)"
    }
}

public struct ProcessSnapshot: Codable, Equatable, Sendable {
    public let pid: pid_t
    public let parentPID: pid_t
    public let name: String
    public let executablePath: String?
    public let startTimeSeconds: UInt64
    public let startTimeMicroseconds: UInt64

    public init(
        pid: pid_t,
        parentPID: pid_t,
        name: String,
        executablePath: String?,
        startTimeSeconds: UInt64,
        startTimeMicroseconds: UInt64 = 0
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }

    /// PID plus start time is stable enough to detect ordinary PID reuse.
    public var identity: String {
        stableIdentity.description
    }

    public var stableIdentity: ProcessIdentity {
        ProcessIdentity(
            pid: pid,
            startTimeSeconds: startTimeSeconds,
            startTimeMicroseconds: startTimeMicroseconds
        )
    }
}

public enum ProcessLookupResult: Equatable, Sendable {
    case running(ProcessSnapshot)
    case missing
    case inaccessible(errorCode: Int32)
}

public enum ProcessProbe {
    public static func runningApplications() -> [RunningApplicationSnapshot] {
        let workspace = NSWorkspace.shared
        let menuBarPID = workspace.menuBarOwningApplication?.processIdentifier

        return workspace.runningApplications
            .map { app in
                RunningApplicationSnapshot(
                    pid: app.processIdentifier,
                    localizedName: app.localizedName,
                    bundleIdentifier: app.bundleIdentifier,
                    executablePath: app.executableURL?.path,
                    isActive: app.isActive,
                    isHidden: app.isHidden,
                    ownsMenuBar: app.processIdentifier == menuBarPID
                )
            }
            .sorted { lhs, rhs in
                let left = lhs.localizedName ?? lhs.bundleIdentifier ?? ""
                let right = rhs.localizedName ?? rhs.bundleIdentifier ?? ""
                return left.localizedStandardCompare(right) == .orderedAscending
            }
    }

    public static func snapshot(pid: pid_t) -> ProcessSnapshot? {
        guard case .running(let snapshot) = lookup(pid: pid) else { return nil }
        return snapshot
    }

    public static func lookup(pid: pid_t) -> ProcessLookupResult {
        guard pid > 0 else { return .missing }

        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let actualSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, expectedSize)
        }
        guard actualSize == expectedSize else {
            let code = errno
            return code == ESRCH
                ? .missing
                : .inaccessible(errorCode: code)
        }

        let name = withUnsafeBytes(of: info.pbi_name) { bytes -> String in
            let content = bytes.prefix { $0 != 0 }
            return String(decoding: content, as: UTF8.self)
        }

        var pathBuffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pathLength = pathBuffer.withUnsafeMutableBytes { buffer in
            proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count))
        }
        let executablePath: String? = if pathLength > 0 {
            String(decoding: pathBuffer.prefix(Int(pathLength)), as: UTF8.self)
        } else {
            nil
        }

        return .running(
            ProcessSnapshot(
                pid: pid_t(bitPattern: info.pbi_pid),
                parentPID: pid_t(bitPattern: info.pbi_ppid),
                name: name,
                executablePath: executablePath,
                startTimeSeconds: UInt64(info.pbi_start_tvsec),
                startTimeMicroseconds: UInt64(info.pbi_start_tvusec)
            )
        )
    }

    public static func allProcesses() -> [ProcessSnapshot] {
        let capacity = max(Int(proc_listallpids(nil, 0)), 1)
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }

        return pids.prefix(Int(count))
            .compactMap(snapshot(pid:))
            .sorted { $0.pid < $1.pid }
    }

    public static func descendants(
        of rootPID: pid_t,
        in processes: [ProcessSnapshot]? = nil
    ) -> [ProcessSnapshot] {
        let snapshots = processes ?? allProcesses()
        let childrenByParent = Dictionary(grouping: snapshots, by: \.parentPID)

        var result: [ProcessSnapshot] = []
        var queue = childrenByParent[rootPID] ?? []
        var visited = Set<pid_t>()

        while !queue.isEmpty {
            let process = queue.removeFirst()
            guard visited.insert(process.pid).inserted else { continue }
            result.append(process)
            queue.append(contentsOf: childrenByParent[process.pid] ?? [])
        }

        return result.sorted { $0.pid < $1.pid }
    }
}
