import Foundation
import IOKit
import IOKit.graphics

public struct DisplayBrightnessSnapshot: Codable, Equatable, Sendable {
    public let registryEntryID: UInt64
    public let serviceClass: String
    public let source: String
    public let brightness: Float?
    public let ioResult: Int32
}

public enum DisplayProbe {
    /// Reads brightness parameters exposed by public IOKit display services.
    /// Some built-in and external displays do not publish this parameter.
    public static func brightnessSnapshots() -> [DisplayBrightnessSnapshot] {
        var iterator: io_iterator_t = 0
        let matchResult = IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IODisplayConnect"),
            &iterator
        )
        guard matchResult == kIOReturnSuccess else { return [] }
        defer { IOObjectRelease(iterator) }

        var snapshots: [DisplayBrightnessSnapshot] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }

            var entryID: UInt64 = 0
            _ = IORegistryEntryGetRegistryEntryID(service, &entryID)

            var brightness: Float = 0
            let result = IODisplayGetFloatParameter(
                service,
                0,
                kIODisplayBrightnessKey as CFString,
                &brightness
            )
            snapshots.append(
                DisplayBrightnessSnapshot(
                    registryEntryID: entryID,
                    serviceClass: "IODisplayConnect",
                    source: "IODisplayGetFloatParameter",
                    brightness: result == kIOReturnSuccess ? brightness : nil,
                    ioResult: result
                )
            )
        }

        // On current Apple-silicon built-in displays, the public
        // IODisplayConnect path may be absent. Read the registry value only as
        // negative feasibility evidence; this is not a supported control API.
        if snapshots.isEmpty,
           let fallback = appleSiliconRegistryObservation()
        {
            snapshots.append(fallback)
        }

        return snapshots.sorted { $0.registryEntryID < $1.registryEntryID }
    }

    private static func appleSiliconRegistryObservation() -> DisplayBrightnessSnapshot? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleARMBacklight")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var entryID: UInt64 = 0
        _ = IORegistryEntryGetRegistryEntryID(service, &entryID)

        let property = IORegistryEntryCreateCFProperty(
            service,
            "IODisplayParameters" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        let parameters = property as? [String: Any]
        let brightness = parameters?["brightness"] as? [String: Any]
        let value = brightness?["value"] as? NSNumber
        let minimum = brightness?["min"] as? NSNumber
        let maximum = brightness?["max"] as? NSNumber

        let normalized: Float? = if let value, let minimum, let maximum,
                                    maximum.floatValue > minimum.floatValue {
            (value.floatValue - minimum.floatValue) / (maximum.floatValue - minimum.floatValue)
        } else {
            nil
        }

        return DisplayBrightnessSnapshot(
            registryEntryID: entryID,
            serviceClass: "AppleARMBacklight",
            source: "IORegistry observation; not a supported setter",
            brightness: normalized,
            ioResult: kIOReturnUnsupported
        )
    }
}

