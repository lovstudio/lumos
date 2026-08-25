import Darwin
import Foundation
import LumosSpikeCore

enum ExitCode: Int32 {
    case usage = 64
    case unavailable = 69
    case software = 70
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    let exitCode: ExitCode
}

private let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
}()

private func printJSON<T: Encodable>(_ value: T) throws {
    let data = try encoder.encode(value)
    guard let output = String(data: data, encoding: .utf8) else {
        throw CLIError(description: "Failed to encode UTF-8 JSON", exitCode: .software)
    }
    print(output)
}

private func usage() {
    print(
        """
        lumos-spike — Lumos technical feasibility probes

        Usage:
          lumos-spike system-state
          lumos-spike safety-state
          lumos-spike power-source
          lumos-spike clamshell-state
          lumos-spike low-power-state
          lumos-spike apps
          lumos-spike process <pid>
          lumos-spike hold <system|display> [seconds]
          lumos-spike network
          lumos-spike display-brightness
          lumos-spike display-sleep-now --confirmed

        The hold command creates a process-scoped IOPM assertion and always
        releases it on normal exit. Duration defaults to 10 seconds and is
        capped at 300 seconds for the Spike.
        """
    )
}

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let command = arguments.first else {
        usage()
        throw CLIError(description: "Missing command", exitCode: .usage)
    }

    switch command {
    case "help", "--help", "-h":
        usage()

    case "system-state":
        try printJSON(SystemStateProbe.snapshot())

    case "safety-state":
        let snapshot = SystemSafetySnapshot(
            systemState: SystemStateProbe.snapshot(),
            powerSource: PowerSourceProbe.snapshot(),
            networkPath: NetworkProbe.currentPath(),
            observedAt: Date()
        )
        struct SafetyResult: Encodable {
            let snapshot: SystemSafetySnapshot
            let decision: SystemSafetyDecision
        }
        try printJSON(
            SafetyResult(
                snapshot: snapshot,
                decision: SystemSafetyPolicy.evaluate(snapshot, batteryFloorPercent: 20)
            )
        )

    case "power-source":
        try printJSON(PowerSourceProbe.snapshot())

    case "clamshell-state":
        try printJSON(ClamshellSleepController().snapshot())

    case "low-power-state":
        try printJSON(LowPowerModeController().snapshot())

    case "apps":
        try printJSON(ProcessProbe.runningApplications())

    case "process":
        guard arguments.count == 2, let pid = pid_t(arguments[1]), pid > 0 else {
            throw CLIError(description: "process requires a positive PID", exitCode: .usage)
        }
        guard let process = ProcessProbe.snapshot(pid: pid) else {
            throw CLIError(description: "PID \(pid) is unavailable or already exited", exitCode: .unavailable)
        }
        struct ProcessResult: Encodable {
            let process: ProcessSnapshot
            let descendants: [ProcessSnapshot]
        }
        try printJSON(ProcessResult(process: process, descendants: ProcessProbe.descendants(of: pid)))

    case "hold":
        guard arguments.count == 2 || arguments.count == 3,
              let kind = PowerAssertionKind(rawValue: arguments[1])
        else {
            throw CLIError(description: "hold requires system or display", exitCode: .usage)
        }
        let seconds = arguments.count == 3 ? Int(arguments[2]) : 10
        guard let seconds, (1...300).contains(seconds) else {
            throw CLIError(description: "duration must be between 1 and 300 seconds", exitCode: .usage)
        }

        let assertion = try PowerAssertion(kind: kind)
        print("pid=\(getpid()) kind=\(kind.rawValue) active=\(assertion.isActive) seconds=\(seconds)")
        fflush(stdout)
        Thread.sleep(forTimeInterval: TimeInterval(seconds))
        try assertion.release()
        print("pid=\(getpid()) kind=\(kind.rawValue) active=\(assertion.isActive) released=true")

    case "network":
        guard let snapshot = NetworkProbe.currentPath() else {
            throw CLIError(description: "NWPathMonitor did not produce a path within the timeout", exitCode: .unavailable)
        }
        try printJSON(snapshot)

    case "display-brightness":
        try printJSON(DisplayProbe.brightnessSnapshots())

    case "display-sleep-now":
        guard arguments == ["display-sleep-now", "--confirmed"] else {
            throw CLIError(
                description: "display-sleep-now visibly blanks the display; pass --confirmed to run it",
                exitCode: .usage
            )
        }
        let result = try DisplaySleepProbe.sleepNow()
        try printJSON(result)
        guard result.terminationStatus == 0 else {
            throw CLIError(
                description: "pmset displaysleepnow exited with \(result.terminationStatus)",
                exitCode: .software
            )
        }

    default:
        usage()
        throw CLIError(description: "Unknown command: \(command)", exitCode: .usage)
    }
}

do {
    try run()
} catch let error as CLIError {
    fputs("error: \(error.description)\n", stderr)
    exit(error.exitCode.rawValue)
} catch {
    fputs("error: \(error)\n", stderr)
    exit(ExitCode.software.rawValue)
}
