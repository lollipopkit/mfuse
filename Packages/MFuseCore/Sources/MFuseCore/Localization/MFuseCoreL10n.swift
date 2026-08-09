import Foundation

enum MFuseCoreL10n {
    private static let table = "Localizable"
    private static let cacheLock = NSLock()
    private static var cachedStrings: [String: [String: String]] = [:]

    static func string(
        _ key: String,
        localeIdentifier: String? = nil,
        fallback: String,
        _ arguments: CVarArg...
    ) -> String {
        let template = localizedTemplate(for: key, localeIdentifier: localeIdentifier) ?? fallback
        guard !arguments.isEmpty else {
            return template
        }
        let locale = localeIdentifier.map(Locale.init(identifier:)) ?? .current
        return String(format: template, locale: locale, arguments: arguments)
    }

    private static func localizedTemplate(for key: String, localeIdentifier: String?) -> String? {
        guard let localeIdentifier else {
            let value = Bundle.module.localizedString(forKey: key, value: nil, table: table)
            return value == key ? nil : value
        }

        let candidates = localizationCandidates(for: localeIdentifier)
        for candidate in candidates {
            guard let value = localizedStrings(for: candidate, table: table)?[key] else {
                continue
            }
            return value
        }

        return nil
    }

    private static func localizationCandidates(for localeIdentifier: String) -> [String] {
        // Underscores first, so `zh_TW` is read as the same locale as `zh-TW`.
        let normalized = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        let lowercased = normalized.lowercased()

        // Neither script has a bundle under its regional identifiers, and the generic path
        // below would resolve every one of them to bare `zh` — which is not shipped either,
        // leaving Chinese users with the English fallback. Hong Kong and Macau are
        // Traditional; every other region is Simplified, which is also the script Chinese
        // defaults to. Listing the Simplified regions instead left the ones nobody thought
        // of — `zh-MY`, `zh-Hans-SG` — falling through to the English fallback.
        if lowercased.hasPrefix("zh-hant") || ["zh-tw", "zh-hk", "zh-mo"].contains(lowercased) {
            return ["zh-Hant", "zh_TW"]
        }
        if lowercased == "zh" || lowercased.hasPrefix("zh-") {
            return ["zh-Hans", "zh_CN", "zh"]
        }

        let languageCode = normalized.split(separator: "-").first.map(String.init)
        return [normalized, localeIdentifier, languageCode].compactMap { $0 }
    }

    private static func localizedStrings(for localization: String, table: String) -> [String: String]? {
        let cacheKey = "\(localization)|\(table)"

        cacheLock.lock()
        if let cached = cachedStrings[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let url = Bundle.module.url(
            forResource: table,
            withExtension: "strings",
            subdirectory: nil,
            localization: localization
        ), let dictionary = NSDictionary(contentsOf: url) as? [String: String] else {
            return nil
        }

        cacheLock.lock()
        if let cached = cachedStrings[cacheKey] {
            cacheLock.unlock()
            return cached
        }
        cachedStrings[cacheKey] = dictionary
        cacheLock.unlock()
        return dictionary
    }
}
