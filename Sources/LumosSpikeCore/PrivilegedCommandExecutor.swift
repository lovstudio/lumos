import AppKit
import Foundation

public enum PrivilegedCommandResult: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed(String)
}

/// Executes a fixed, app-authored command through the standard macOS
/// administrator authorization dialog. Callers must never interpolate user
/// input into the command.
public enum PrivilegedCommandExecutor {
    public static func execute(_ command: String) -> PrivilegedCommandResult {
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
            ?? "macOS 拒绝了系统电源设置变更。"
        return .failed(message)
    }

    private static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
