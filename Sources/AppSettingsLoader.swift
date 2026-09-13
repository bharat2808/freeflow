import Foundation

struct StoredShortcutConfiguration {
    let hold: ShortcutBinding
    let toggle: ShortcutBinding
    let copyAgain: ShortcutBinding
    let generate: ShortcutBinding
    let didUpdateHoldStoredValue: Bool
    let didUpdateToggleStoredValue: Bool
    let didUpdateCopyAgainStoredValue: Bool
}

struct StoredOptionalShortcut {
    let binding: ShortcutBinding?
    let didUpdateStoredValue: Bool
}

enum AppSettingsLoader {
    private struct StoredShortcutLoadResult {
        let binding: ShortcutBinding?
        let hadStoredValue: Bool
        let didNormalize: Bool
    }

    private static let deprecatedDefaultPostProcessingFallbackModel =
        "meta-llama/llama-4-scout-17b-16e-instruct"
    private static let deprecatedDefaultContextModel =
        "meta-llama/llama-4-scout-17b-16e-instruct"

    static func loadStoredAPIKey(account: String) -> String {
        guard let storedKey = AppSettingsStorage.load(account: account) else { return "" }
        let trimmed = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : storedKey
    }

    static func loadStoredAPIBaseURL(account: String) -> String {
        guard let stored = AppSettingsStorage.load(account: account) else {
            return AppState.defaultAPIBaseURL
        }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AppState.defaultAPIBaseURL : stored
    }

    static func loadStoredContextModel(key: String) -> String {
        guard let stored = UserDefaults.standard.string(forKey: key) else {
            return AppState.defaultContextModel
        }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == deprecatedDefaultContextModel {
            UserDefaults.standard.set(AppState.defaultContextModel, forKey: key)
            return AppState.defaultContextModel
        }
        return trimmed.isEmpty ? AppState.defaultContextModel : trimmed
    }

    static func loadStoredPostProcessingFallbackModel(key: String) -> String {
        guard let stored = UserDefaults.standard.string(forKey: key) else {
            return AppState.defaultPostProcessingFallbackModel
        }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == deprecatedDefaultPostProcessingFallbackModel {
            UserDefaults.standard.set(AppState.defaultPostProcessingFallbackModel, forKey: key)
            return AppState.defaultPostProcessingFallbackModel
        }
        return trimmed.isEmpty ? AppState.defaultPostProcessingFallbackModel : trimmed
    }

    static func loadShortcutConfiguration(
        holdKey: String,
        toggleKey: String,
        copyAgainKey: String,
        generateKey: String? = nil
    ) -> StoredShortcutConfiguration {
        let legacyPreset = ShortcutPreset(
            rawValue: UserDefaults.standard.string(forKey: "hotkey_option") ?? ShortcutPreset.fnKey.rawValue
        ) ?? .fnKey
        let hold = legacyPreset.binding
        let toggle = hold.withAddedModifiers(.command)
        let storedHold = loadShortcut(forKey: holdKey)
        let storedToggle = loadShortcut(forKey: toggleKey)
        let storedCopyAgain = loadShortcut(forKey: copyAgainKey)
        let storedGenerate = generateKey.map { loadShortcut(forKey: $0) }
        return StoredShortcutConfiguration(
            hold: storedHold.binding ?? hold,
            toggle: storedToggle.binding ?? toggle,
            copyAgain: storedCopyAgain.binding ?? .disabled,
            generate: storedGenerate?.binding ?? .disabled,
            didUpdateHoldStoredValue: storedHold.binding == nil || storedHold.didNormalize,
            didUpdateToggleStoredValue: storedToggle.binding == nil || storedToggle.didNormalize,
            didUpdateCopyAgainStoredValue: storedCopyAgain.didNormalize
        )
    }

    static func loadSavedCustomShortcut(
        forKey key: String,
        fallback: ShortcutBinding?
    ) -> StoredOptionalShortcut {
        let stored = loadShortcut(forKey: key)
        if let binding = stored.binding {
            return StoredOptionalShortcut(binding: binding, didUpdateStoredValue: stored.didNormalize)
        }
        return StoredOptionalShortcut(
            binding: fallback,
            didUpdateStoredValue: stored.hadStoredValue || fallback != nil
        )
    }

    static func loadOptionalStoredAPIValue(account: String) -> String {
        let stored = AppSettingsStorage.load(account: account) ?? ""
        return stored.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeTranscriptionLanguage(_ language: String) -> String {
        let normalized = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard AppState.transcriptionLanguageOptions.contains(where: { $0.code == normalized }) else {
            return ""
        }
        return normalized
    }

    private static func loadShortcut(forKey key: String) -> StoredShortcutLoadResult {
        guard let data = UserDefaults.standard.data(forKey: key) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: false, didNormalize: false)
        }
        guard let decoded = try? JSONDecoder().decode(ShortcutBinding.self, from: data) else {
            return StoredShortcutLoadResult(binding: nil, hadStoredValue: true, didNormalize: false)
        }
        let normalized = decoded.normalizedForStorageMigration()
        return StoredShortcutLoadResult(
            binding: normalized,
            hadStoredValue: true,
            didNormalize: normalized != decoded
        )
    }
}
