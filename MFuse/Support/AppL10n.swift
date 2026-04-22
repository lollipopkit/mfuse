import Foundation

enum AppL10n {
    static func string(_ key: String, fallback: String, _ arguments: CVarArg...) -> String {
        let template = NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback, comment: "")
        guard !arguments.isEmpty else {
            return template
        }
        return String(format: template, locale: .current, arguments: arguments)
    }
}
