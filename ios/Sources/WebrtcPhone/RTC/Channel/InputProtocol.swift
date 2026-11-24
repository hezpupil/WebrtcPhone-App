import Foundation

/// DataChannel 文本发送抽象（真实实现是 SafeChannel，单测用内存实现）
typealias TextSender = (String) -> Bool

/// Android KeyEvent 常量（避免在纯逻辑层依赖 UIKit）
enum Keys {
    static let home = 3, back = 4, volumeUp = 24, volumeDown = 25, power = 26
    static let tab = 61, enter = 66, del = 67, menu = 82, mediaPlayPause = 85
    static let pageUp = 92, pageDown = 93, escape = 111, forwardDel = 112
    static let volumeMute = 164, appSwitch = 187, screenshot = 120
    static let notification = 83, wakeup = 224, sleep = 223
}

enum TouchAction {
    static let down = 0, up = 1, move = 2, cancel = 3
}

/// input-channel 协议编码。对齐 Android 端 InputProtocol.kt。
/// 逐字段对齐 agent webrtc.go 的 input-channel OnMessage。
final class InputProtocol {
    private let sender: TextSender
    private let viewOnly: () -> Bool
    private let clock: () -> Int64
    private var seq: Int64 = 0
    private let lock = NSLock()

    init(sender: @escaping TextSender, viewOnly: @escaping () -> Bool,
         clock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.sender = sender
        self.viewOnly = viewOnly
        self.clock = clock
    }

    private func nextSeq() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        seq += 1
        return seq
    }

    /// 坐标为视频帧像素坐标，w/h 为帧尺寸（agent 依此换算真实屏幕）
    func touch(pointerId: Int, action: Int, x: Int, y: Int, w: Int, h: Int) -> Bool {
        guard !viewOnly(), w > 0, h > 0 else { return false }
        let a = action == TouchAction.cancel ? TouchAction.up : action
        return send([
            "type": "touch", "id": pointerId, "seq": nextSeq(),
            "client_ts_ms": clock(), "action": a,
            "x": min(max(x, 0), w), "y": min(max(y, 0), h), "w": w, "h": h,
        ])
    }

    func key(_ keycode: Int, action: Int, repeatTimes: Int = 0, meta: Int = 0) -> Bool {
        guard !viewOnly() else { return false }
        return send(["type": "inject_keycode", "action": action, "keycode": keycode,
                     "repeat": repeatTimes, "meta": meta])
    }

    func press(_ keycode: Int, meta: Int = 0) -> Bool {
        key(keycode, action: 0, meta: meta) && key(keycode, action: 1, meta: meta)
    }

    func longPress(_ keycode: Int) -> Bool {
        guard key(keycode, action: 0) else { return false }
        for i in 1...20 { _ = key(keycode, action: 0, repeatTimes: i) }
        return key(keycode, action: 1)
    }

    /// 非 ASCII 由 agent 自动转剪贴板粘贴落屏
    func text(_ text: String) -> Bool {
        guard !viewOnly(), !text.isEmpty else { return false }
        return send(["type": "inject_text", "text": text])
    }

    func scroll(x: Int, y: Int, w: Int, h: Int, hScroll: Int, vScroll: Int) -> Bool {
        guard !viewOnly(), w > 0, h > 0 else { return false }
        return send([
            "type": "inject_scroll", "seq": nextSeq(), "client_ts_ms": clock(),
            "x": x, "y": y, "w": w, "h": h, "scroll_h": hScroll, "scroll_v": vScroll,
        ])
    }

    /// 勿用：agent 收到 hard_keyboard=on 会停止视频
    func hardKeyboard(_ on: Bool) -> Bool {
        guard !viewOnly() else { return false }
        return send(["type": "hard_keyboard", "action": on ? "on" : "off"])
    }

    private func send(_ obj: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return false }
        return sender(text)
    }
}
