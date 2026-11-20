import Foundation

/// Looks up a string by its Android resource name (see scripts/convert-strings.py).
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Formatted lookup; Android placeholders (%1$s, %d) are converted to %1$@ / %d.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: args)
}

enum Format {
    static func duration(ms: Int) -> String {
        let total = max(0, ms / 1000)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ t: Double) -> String {
        guard t > 0 else { return "-" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
