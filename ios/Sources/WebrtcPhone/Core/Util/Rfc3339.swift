import Foundation

/// RFC3339 时间解析。对齐 Android 端 core/util/Rfc3339.kt。
/// 空串、"null"、以 "0001-" 开头 → nil；纳秒截前 3 位；z 归一为 Z。
enum Rfc3339 {
    static func parse(_ value: String?) -> Date? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "null", !raw.hasPrefix("0001-") else { return nil }

        var s = raw.replacingOccurrences(of: "z", with: "Z")
        // 纳秒截前 3 位（毫秒）
        if let dot = s.firstIndex(of: ".") {
            let after = s.index(after: dot)
            var end = after
            var digits = 0
            while end < s.endIndex, s[end].isNumber {
                digits += 1
                end = s.index(after: end)
                if digits == 3 { break }
            }
            if digits > 0 {
                s = String(s[..<after]) + String(s[after..<end]) + String(s[end...])
            }
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: s) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: s)
    }
}
