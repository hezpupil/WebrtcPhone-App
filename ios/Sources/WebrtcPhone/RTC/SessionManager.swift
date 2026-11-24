import Foundation
import WebRTC

/// 进程级投屏会话管理。对齐 Android 端 SessionManager.kt：
/// - 同一时刻只维护一个会话；投屏页重建直接复用
/// - 后台只“脱离”渲染，5 分钟后才真正断开
/// - 可恢复错误在前台自动重连（指数退避，最多 3 次）
/// - 改画质/切镜头 = 以新 target 重建会话
@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var session: RtcSession?
    @Published private(set) var retry = 0

    private let engine: RtcEngine
    private let httpFactory: HttpClientFactory
    private var renderer: RTCVideoRenderer?
    private var audioEnabled = true
    private var keepAliveTask: Task<Void, Never>?
    private var autoReconnect = true

    /// 复用 key：<endpoint, device, auth>，最近 64 条 LRU
    private var resumeKeys: [String: String] = [:]
    private var resumeOrder: [String] = []

    init(engine: RtcEngine = .shared, httpFactory: HttpClientFactory) {
        self.engine = engine
        self.httpFactory = httpFactory
    }

    func setAutoReconnect(_ enabled: Bool) { autoReconnect = enabled }

    func open(_ target: StreamTarget) -> RtcSession {
        keepAliveTask?.cancel()
        if let cur = session, cur.target == target, !cur.phase.value.isTerminal { return cur }
        retry = 0
        return replace(target)
    }

    @discardableResult
    func restart(_ target: StreamTarget? = nil) -> RtcSession? {
        guard let t = target ?? session?.target else { return nil }
        retry = 0
        return replace(t)
    }

    func attach(_ renderer: RTCVideoRenderer) {
        keepAliveTask?.cancel()
        self.renderer = renderer
        session?.setRenderer(renderer)
    }

    func detach(_ renderer: RTCVideoRenderer? = nil) {
        if let renderer, self.renderer == nil { return }
        self.renderer = nil
        session?.setRenderer(nil)
        keepAliveTask?.cancel()
        guard session != nil else { return }
        keepAliveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.close(preserveProjection: true)
        }
    }

    func setAudioEnabled(_ enabled: Bool) {
        audioEnabled = enabled
        session?.setAudioEnabled(enabled)
    }

    func close(endProjection: Bool = false, preserveProjection: Bool = false) {
        if endProjection, let s = session {
            resumeKeys.removeValue(forKey: resumeScope(s.target))
        } else if !preserveProjection {
            resumeKeys.removeAll(); resumeOrder.removeAll()
        }
        keepAliveTask?.cancel()
        session?.close(endProjection: endProjection)
        session = nil
        retry = 0
    }

    private func resumeScope(_ target: StreamTarget) -> String {
        let authKey: String
        switch target.auth {
        case .user(let token): authKey = "u:\(token)"
        case .share(let t, let p): authKey = "s:\(t):\(p)"
        }
        return "\(target.endpoint.serialize())|\(target.deviceId)|\(authKey)"
    }

    private func replace(_ target: StreamTarget) -> RtcSession {
        let old = session
        let scope = resumeScope(target)
        let key: String
        if let existing = resumeKeys[scope] { key = existing }
        else {
            key = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            resumeKeys[scope] = key
            resumeOrder.append(scope)
            if resumeOrder.count > 64, let eldest = resumeOrder.first {
                resumeOrder.removeFirst(); resumeKeys.removeValue(forKey: eldest)
            }
        }
        let s = RtcSession(factory: engine.factory, httpFactory: httpFactory,
                           target: target, projectionResumeKey: key)
        renderer.map { s.setRenderer($0) }
        s.setAudioEnabled(audioEnabled)
        session = s
        old?.close()
        s.start(delay: old != nil ? 0.3 : 0)
        s.phase.subscribe { [weak self] phase in
            Task { @MainActor in
                guard let self, self.session === s, !Task.isCancelled else { return }
                if phase == .connected { self.retry = 0 }
                if case .failed(_, let retryable, _) = phase,
                   retryable, self.autoReconnect, self.renderer != nil, self.retry < 3 {
                    let attempt = self.retry + 1
                    self.retry = attempt
                    let keep = attempt
                    try? await Task.sleep(nanoseconds: UInt64(1000 * (1 << (attempt - 1))) * 1_000_000)
                    guard !Task.isCancelled, self.session === s else { return }
                    self.retry = keep
                    _ = self.replace(target)
                }
            }
        }
        return s
    }

    deinit {
        keepAliveTask?.cancel()
    }
}
