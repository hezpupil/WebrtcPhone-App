import Foundation

/// 对齐 Android 端 core/util/Formatters.kt
enum Formatters {
    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()
    private static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    static func dateTime(_ d: Date?) -> String {
        guard let d else { return "-" }
        return full.string(from: d)
    }

    static func shortDateTime(_ d: Date?) -> String {
        guard let d else { return "-" }
        return short.string(from: d)
    }

    /// 刚刚 / N分钟前|后 / N小时前|后 / N天前|后
    static func relative(_ d: Date?) -> String {
        guard let d else { return "-" }
        let sec = Int(Date().timeIntervalSince(d))
        let abs = Swift.abs(sec)
        if abs < 60 { return "刚刚" }
        let suffix = sec >= 0 ? "前" : "后"
        if abs < 3600 { return "\(abs / 60)分钟\(suffix)" }
        if abs < 86400 { return "\(abs / 3600)小时\(suffix)" }
        return "\(abs / 86400)天\(suffix)"
    }

    /// 3天4小时 / 2小时5分 / 12分钟 / N秒 / 已到期(≤0)
    static func duration(_ seconds: Int64) -> String {
        if seconds <= 0 { return "已到期" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if days > 0 { return hours > 0 ? "\(days)天\(hours)小时" : "\(days)天" }
        if hours > 0 { return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时" }
        if minutes > 0 { return "\(minutes)分钟" }
        return "\(secs)秒"
    }

    /// B/KB/MB/GB/TB；v≥100 用整数否则 1 位小数
    static func bytes(_ v: Int64) -> String {
        let value = Double(v)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var result = value
        var i = 0
        while result >= 1024 && i < units.count - 1 { result /= 1024; i += 1 }
        if result >= 100 { return String(format: "%.0f%@", result, units[i]) }
        return String(format: "%.1f%@", result, units[i])
    }
}
