import Foundation

/// Parses FTP LIST output (Unix ls-l format) into structured entries.
struct FTPDirectoryParser {

    struct Entry {
        let name: String
        let isDirectory: Bool
        let size: UInt64
        let modificationDate: Date?
        let permissions: UInt16?
    }

    /// Parse Unix-style `ls -l` output lines.
    /// Example: `drwxr-xr-x  2 user group  4096 Jan 01 12:00 dirname`
    static func parse(_ listing: String) -> [Entry] {
        listing
            .components(separatedBy: "\n")
            .compactMap { parseLine($0) }
    }

    private static func parseLine(_ line: String) -> Entry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Skip "total" line
        guard !trimmed.hasPrefix("total ") else { return nil }

        // Unix format: permissions links owner group size date name
        // At least 9 fields separated by whitespace, but name can have spaces
        let parts = trimmed.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
        guard parts.count >= 9 else { return nil }

        let permsStr = String(parts[0])
        guard permsStr.count >= 10 else { return nil }

        let isDir = permsStr.first == "d"
        let isLink = permsStr.first == "l"
        let size = UInt64(parts[4]) ?? 0

        // Parse date: "Jan 01 12:00" or "Jan 01  2025"
        let dateStr = "\(parts[5]) \(parts[6]) \(parts[7])"
        let date = parseDate(dateStr)

        // Name is everything after the 8th field
        var name = String(parts[8])
        // If it's a symlink, strip the " -> target" part
        if isLink, let arrowRange = name.range(of: " -> ") {
            name = String(name[..<arrowRange.lowerBound])
        }

        guard name != "." && name != ".." else { return nil }

        let permissions = parsePermissions(permsStr)

        return Entry(
            name: name,
            isDirectory: isDir,
            size: size,
            modificationDate: date,
            permissions: permissions
        )
    }

    private static func parseDate(_ str: String) -> Date? {
        // Try "Jan 01 12:00" (current year) or "Jan 01  2025"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")

        // With time
        formatter.dateFormat = "MMM dd HH:mm"
        if let d = formatter.date(from: str) {
            // Infer the most recent plausible year for listings without a year field.
            var cal = Calendar.current
            cal.timeZone = TimeZone(identifier: "UTC")!
            let now = Date()
            let year = cal.component(.year, from: now)
            let currentMonth = cal.component(.month, from: now)
            var comps = cal.dateComponents([.month, .day, .hour, .minute], from: d)
            let parsedMonth = comps.month ?? currentMonth
            comps.year = parsedMonth > currentMonth ? year - 1 : year
            return cal.date(from: comps)
        }

        // With year
        formatter.dateFormat = "MMM dd yyyy"
        return formatter.date(from: str)
    }

    /// Parse Unix permission string "drwxr-xr-x" to numeric.
    private static func parsePermissions(_ str: String) -> UInt16? {
        guard str.count >= 10 else { return nil }
        let chars = Array(str)
        var mode: UInt16 = 0

        // Owner
        if chars[1] == "r" { mode |= 0o400 }
        if chars[2] == "w" { mode |= 0o200 }
        if chars[3] == "x" || chars[3] == "s" { mode |= 0o100 }
        if chars[3] == "s" || chars[3] == "S" { mode |= 0o4000 }

        // Group
        if chars[4] == "r" { mode |= 0o040 }
        if chars[5] == "w" { mode |= 0o020 }
        if chars[6] == "x" || chars[6] == "s" { mode |= 0o010 }
        if chars[6] == "s" || chars[6] == "S" { mode |= 0o2000 }

        // Other
        if chars[7] == "r" { mode |= 0o004 }
        if chars[8] == "w" { mode |= 0o002 }
        if chars[9] == "x" || chars[9] == "t" { mode |= 0o001 }
        if chars[9] == "t" || chars[9] == "T" { mode |= 0o1000 }

        return mode
    }
}
