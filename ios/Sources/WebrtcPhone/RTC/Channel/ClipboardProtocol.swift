import Foundation

/// clipboard-channel 协议。对齐 Android 端 ClipboardProtocol.kt。
/// 带防回环（lastSynced）与键盘临时剪贴板过滤（source == "keyboard"）。
final class ClipboardProtocol {
    private let sender: TextSender
    private let enabled: () -> Bool
    private var lastSynced: String?
    private let lock = NSLock()

    init(sender: @escaping TextSender, enabled: @escaping () -> Bool) {
        self.sender = sender
        self.enabled = enabled
    }

    func setClipboard(_ text: String, paste: Bool = false, force: Bool = false) -> Bool {
        guard enabled(), !text.isEmpty else { return false }
        lock.lock()
        if !force && !paste && text == lastSynced { lock.unlock(); return false }
        lock.unlock()
        let obj: [String: Any] = ["type": "set_clipboard", "text": text,
                                  "paste": paste, "source": "local"]
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8), sender(s) else { return false }
        lock.lock(); lastSynced = text; lock.unlock()
        return true
    }

    func getClipboard() -> Bool {
        guard enabled(), let data = try? JSONSerialization.data(withJSONObject: ["type": "get_clipboard"]),
              let s = String(data: data, encoding: .utf8) else { return false }
        return sender(s)
    }

    /// 解析入站 clipboard 消息，返回可接受文本
    func parseIncoming(_ text: String, force: Bool = false) -> String? {
        guard let data = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (o["type"] as? String) == "clipboard",
              let value = o["text"] as? String, !value.isEmpty else { return nil }
        if o["source"] as? String == "keyboard" { return nil }
        lock.lock(); defer { lock.unlock() }
        if !force && value == lastSynced { return nil }
        lastSynced = value
        return value
    }

    func reset() { lock.lock(); lastSynced = nil; lock.unlock() }
}
