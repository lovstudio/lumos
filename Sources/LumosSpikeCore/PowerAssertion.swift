import Foundation
import IOKit.pwr_mgt

public enum PowerAssertionKind: String, Codable, CaseIterable, Sendable {
    case systemIdleSleep = "system"
    case displayIdleSleep = "display"

    var ioKitType: CFString {
        switch self {
        case .systemIdleSleep:
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString
        case .displayIdleSleep:
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString
        }
    }

    public var assertionName: String {
        switch self {
        case .systemIdleSleep:
            "Lumos Spike System Idle Lease"
        case .displayIdleSleep:
            "Lumos Spike Display Idle Lease"
        }
    }
}

public struct PowerAssertionFailure: Error, CustomStringConvertible, Equatable, Sendable {
    public let operation: String
    public let result: IOReturn

    public var description: String {
        "\(operation) failed with IOKit result 0x\(String(UInt32(bitPattern: result), radix: 16))"
    }
}

/// A process-scoped IOPM assertion. Releasing the object releases the assertion.
/// The system can still override this request for lid close, user-requested sleep,
/// low battery, thermal emergencies, and other non-idle sleep reasons.
public final class PowerAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var assertionID: IOPMAssertionID?

    public let kind: PowerAssertionKind

    public init(kind: PowerAssertionKind, reason: String? = nil) throws {
        self.kind = kind

        var newID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kind.ioKitType,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            (reason ?? kind.assertionName) as CFString,
            &newID
        )
        guard result == kIOReturnSuccess else {
            throw PowerAssertionFailure(operation: "create \(kind.rawValue) assertion", result: result)
        }
        assertionID = newID
    }

    public var isActive: Bool {
        lock.withLock { assertionID != nil }
    }

    public func release() throws {
        let id = lock.withLock { () -> IOPMAssertionID? in
            defer { assertionID = nil }
            return assertionID
        }
        guard let id else { return }

        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else {
            throw PowerAssertionFailure(operation: "release \(kind.rawValue) assertion", result: result)
        }
    }

    deinit {
        try? release()
    }
}
