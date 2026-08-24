import AppKit
import Darwin
import Foundation

@main
enum LumosAppEntry {
    @MainActor
    static func main() {
        guard let instanceLock = LumosInstanceLock() else {
            print("Lumos dev is already running")
            return
        }

        let application = NSApplication.shared
        let delegate = LumosAppDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime((delegate, instanceLock)) {}
    }
}

final class LumosInstanceLock {
    private let fileDescriptor: Int32

    init?() {
        let path = "/tmp/ai.lovstudio.lumos.dev.\(getuid()).lock"
        let descriptor = Darwin.open(
            path,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return nil }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        fileDescriptor = descriptor
    }

    deinit {
        _ = flock(fileDescriptor, LOCK_UN)
        Darwin.close(fileDescriptor)
    }
}
