import Foundation

/// 构建标识：每次发布前手动更新，出现在 trail/崩溃报告中，
/// 用于确认用户实际运行的二进制版本（版本号不升时尤为关键）。
enum AppBuild {
    static let tag = "ios-20261126-1830"
}

/// 连接过程埋点（trail.log）：崩溃时自动合并进崩溃报告，
/// 用于远端定位「卡在哪一步 abort」。写入频率极低（每次连接 < 30 条）。
enum Trail {
    static let fileName = "trail.log"
    private static let maxBytes = 32_768
    private static let lock = NSLock()

    static func mark(_ event: String) {
        lock.lock(); defer { lock.unlock() }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = dir.appendingPathComponent(fileName)
        let ts = String(format: "%.3f", Date().timeIntervalSince1970)
        var data = (try? Data(contentsOf: url)) ?? Data()
        // 文件过大时保留后半段，避免无限增长
        if data.count > maxBytes { data = data.suffix(maxBytes / 2) }
        data.append(Data("\(ts) \(event)\n".utf8))
        try? data.write(to: url, options: .atomic)
    }

    /// 读取尾部若干行（仅在正常运行上下文调用，不可用于信号处理器内）。
    static func tail(maxLines: Int = 60) -> String? {
        lock.lock(); defer { lock.unlock() }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let url = dir.appendingPathComponent(fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > maxLines { lines = Array(lines.suffix(maxLines)) }
        return lines.joined(separator: "\n")
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
    }
}
