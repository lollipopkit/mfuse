import Foundation

enum MFuseCoreL10n {
    private static let table = "Localizable"

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
            guard let url = Bundle.module.url(
                forResource: table,
                withExtension: "strings",
                subdirectory: nil,
                localization: candidate
            ) else {
                continue
            }
            guard let dictionary = NSDictionary(contentsOf: url) as? [String: String],
                  let value = dictionary[key] else {
                continue
            }
            return value
        }

        let fallbackValue = Bundle.module.localizedString(forKey: key, value: nil, table: table)
        return fallbackValue == key ? nil : fallbackValue
    }

    private static func localizationCandidates(for localeIdentifier: String) -> [String] {
        switch localeIdentifier.lowercased() {
        case "zh-cn", "zh-hans", "zh":
            return ["zh-Hans", "zh_CN", "zh"]
        case "zh-tw", "zh-hant":
            return ["zh-Hant", "zh_TW"]
        default:
            let normalized = localeIdentifier.replacingOccurrences(of: "_", with: "-")
            let languageCode = normalized.split(separator: "-").first.map(String.init)
            return [normalized, localeIdentifier, languageCode].compactMap { $0 }
        }
    }
}
