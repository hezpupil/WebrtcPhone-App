import Foundation
import WebRTC

/// DataChannel 安全封装。对齐 Android 端 SafeChannel.kt。
/// native 释放后再调用会 SIGSEGV（try/catch 拦不住），所以 send/state 都在锁内判 closed；
/// 回调只拷贝数据后转投，signaling 线程永不等待本锁（防死锁）。
final class SafeChannel: NSObject, RTCDataChannelDelegate {
    private let channel: RTCDataChannel
    private let lock = NSLock()
    private var closed = false
    private var messageHandler: ((Data, Bool) -> Void)?
    private var stateHandler: ((RTCDataChannelState) -> Void)?

    init(_ channel: RTCDataChannel) {
        self.channel = channel
        super.init()
        self.channel.delegate = self
    }

    var label: String { channel.label }

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return !closed && channel.readyState == .open
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard let data = text.data(using: .utf8) else { return false }
        return sendBytes(data, binary: false)
    }

    @discardableResult
    func sendBytes(_ data: Data, binary: Bool = true) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if closed || channel.readyState != .open { return false }
        let buffer = RTCDataBuffer(data: data, isBinary: binary)
        return channel.sendData(buffer)
    }

    func bufferedAmount() -> UInt64 { channel.bufferedAmount }

    func observe(message: ((Data, Bool) -> Void)? = nil, state: ((RTCDataChannelState) -> Void)? = nil) {
        lock.lock()
        self.messageHandler = message
        self.stateHandler = state
        lock.unlock()
    }

    func release() {
        lock.lock()
        closed = true
        lock.unlock()
        channel.delegate = nil
        channel.close()
    }

    // MARK: RTCDataChannelDelegate — 只拷贝数据，不在此处同步 send/close
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let handler = lock.lock { stateHandler }
        handler?(dataChannel.readyState)
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        let isBinary = buffer.isBinary
        let handler = lock.lock { messageHandler }
        handler?(data, isBinary)
    }
}

private extension NSLock {
    func lock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
