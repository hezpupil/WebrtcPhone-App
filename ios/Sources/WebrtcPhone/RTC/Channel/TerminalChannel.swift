import Foundation

/// adb-channel 协议。对齐 Android 端 TerminalChannel.kt。
/// 首帧（binary）：UTF-8 {"type":"init","rows":N,"cols":M}，之后双向裸 PTY 字节。
/// agent 不支持 resize——init 后任何字节都写入 shell。
final class TerminalChannel {
    private let sendBytes: (Data) -> Bool
    private var initialized = false
    private var outputBuffer = Data()
    private let bufferLimit = 512 * 1024
    private let lock = NSLock()
    private var outputHandler: ((Data) -> Void)?

    init(sendBytes: @escaping (Data) -> Bool) { self.sendBytes = sendBytes }

    /// 注册 PTY 输出回调（引用输出会被转发到这里）
    func observe(_ handler: @escaping (Data) -> Void) {
        lock.lock(); outputHandler = handler; lock.unlock()
    }

    /// 由数据通道收到 adb-channel 二进制帧时调用
    @discardableResult
    func receive(_ data: Data) -> Bool {
        _ = append(data)
        lock.lock(); let handler = outputHandler; lock.unlock()
        handler?(data)
        return true
    }

    @discardableResult
    func start(rows: Int, cols: Int) -> Bool {
        lock.lock()
        if initialized { lock.unlock(); return true }
        lock.unlock()
        let payload: [String: Any] = ["type": "init", "rows": rows, "cols": cols]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        guard sendBytes(data) else { return false }
        lock.lock(); initialized = true; lock.unlock()
        return true
    }

    @discardableResult
    func write(_ bytes: Data) -> Bool {
        lock.lock()
        let ok = initialized && sendBytes(bytes)
        lock.unlock()
        return ok
    }

    /// 追加 PTY 输出；超出容量时重置为最近内容
    func append(_ data: Data) -> (reset: Bool, skipped: Int64, bytes: Data) {
        lock.lock(); defer { lock.unlock() }
        var reset = false
        var skipped: Int64 = 0
        if outputBuffer.count + data.count > bufferLimit {
            let keep = max(0, bufferLimit - data.count)
            skipped = Int64(max(0, outputBuffer.count - keep))
            outputBuffer = Data(outputBuffer.suffix(keep))
            reset = true
        }
        outputBuffer.append(data)
        return (reset, skipped, data)
    }

    func clear() { lock.lock(); outputBuffer.removeAll(); lock.unlock() }
    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return initialized }
}
