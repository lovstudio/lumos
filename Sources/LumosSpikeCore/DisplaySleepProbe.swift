import Foundation

public struct DisplaySleepResult: Codable, Equatable, Sendable {
    public let executable: String
    public let terminationStatus: Int32
    public let standardOutput: String
    public let standardError: String
}

public enum DisplaySleepProbe {
    public static let executable = "/usr/bin/pmset"

    public static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: executable)
    }

    /// Invokes the system's `pmset displaysleepnow` command. The CLI requires
    /// an explicit confirmation flag because this visibly blanks the display.
    public static func sleepNow() throws -> DisplaySleepResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["displaysleepnow"]

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        try process.run()
        process.waitUntilExit()

        return DisplaySleepResult(
            executable: executable,
            terminationStatus: process.terminationStatus,
            standardOutput: String(
                decoding: output.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ),
            standardError: String(
                decoding: error.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            )
        )
    }
}

