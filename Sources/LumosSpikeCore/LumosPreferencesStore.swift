import Foundation

public struct LumosPreferencesStore {
    public static let defaultSuiteName = "ai.lovstudio.lumos.dev"
    public static let defaultKey = "preferences.v1"

    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        suiteName: String = defaultSuiteName,
        key: String = defaultKey
    ) {
        self.defaults = Bundle.main.bundleIdentifier == suiteName
            ? .standard
            : (UserDefaults(suiteName: suiteName) ?? .standard)
        self.key = key
    }

    public init(defaults: UserDefaults, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> LumosPreferences {
        guard let data = defaults.data(forKey: key),
              var preferences = try? decoder.decode(LumosPreferences.self, from: data)
        else {
            return .defaults
        }
        preferences.normalize()
        if let migratedData = try? encoder.encode(preferences), migratedData != data {
            defaults.set(migratedData, forKey: key)
        }
        return preferences
    }

    public func save(_ preferences: LumosPreferences) throws {
        defaults.set(try encoder.encode(preferences), forKey: key)
    }
}
