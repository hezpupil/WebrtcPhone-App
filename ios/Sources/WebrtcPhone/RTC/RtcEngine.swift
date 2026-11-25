import Foundation
import WebRTC

/// 进程级 WebRTC 引擎：PeerConnectionFactory 只创建一次、跨会话复用。
/// 对齐 Android 端 RtcEngine.kt（重连/切画质无需重建工厂，省去初始化与解码器探测）。
final class RtcEngine {
    static let shared = RtcEngine()

    /// WebRTC 工厂（线程安全，首次访问时初始化）。
    /// stasel/WebRTC 的默认 init 已带 H264 编解码工厂与硬件解码支持。
    lazy var factory: RTCPeerConnectionFactory = RTCPeerConnectionFactory()

    private init() {}

    /// 应用启动早期预热，避免首个会话卡在初始化；埋点便于定位工厂创建阶段的 abort。
    func warmUp() {
        Trail.mark("engine:factory-creating")
        _ = factory
        Trail.mark("engine:factory-ready")
    }
}
