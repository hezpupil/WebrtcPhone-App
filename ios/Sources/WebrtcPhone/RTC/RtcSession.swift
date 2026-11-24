import Foundation
import WebRTC

/// 把远端视频帧转发给当前 UI 渲染器，并检测首帧/分辨率。
/// 渲染目标可随页面重建切换；为 nil 时丢帧（后台保活）。
private final class FrameSink: NSObject, RTCVideoRenderer {
    weak var owner: RtcSession?
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame, let owner else { return }
        owner.onVideoFrame(frame)
    }
}

/// 一次完整 WebRTC 连接（信令 WS + PeerConnection + DataChannels）。
/// 对齐 Android 端 RtcSession.kt：所有状态变更与 PC/DC 生命周期都在单线程 queue 上执行。
final class RtcSession: NSObject, RTCPeerConnectionDelegate {
    private let factory: RTCPeerConnectionFactory
    private let target: StreamTarget
    private let httpFactory: HttpClientFactory
    private let queue = DispatchQueue(label: "webrtc.session", qos: .userInitiated)
    private let projectionResumeKey: String?

    private var signaling: SignalingClient?
    private var pc: RTCPeerConnection?
    private var pendingCandidates: [RTCIceCandidate] = []
    private var remoteDescriptionSet = false
    private var attachedTracks = Set<String>()

    private var inputChannel: SafeChannel?
    private var clipboardChannel: SafeChannel?
    private var fileChannel: SafeChannel?
    private var adbChannel: SafeChannel?
    private var agentChannels: [SafeChannel] = []

    private var statsTimer: DispatchSourceTimer?
    private var connectTimer: DispatchSourceTimer?
    private var firstFrameTimer: DispatchSourceTimer?
    private var interruptTimer: DispatchSourceTimer?
    private var closed = false
    private let statsCalc = StatsCalculator()

    private let frameSink = FrameSink()
    private let frameLock = NSLock()
    private var renderer: RTCVideoRenderer?

    // MARK: 状态（线程安全，只读可从任意线程）
    private let phaseSubject = StateSubject<ConnectionPhase>(.signaling)
    var phase: AnyStatePublisher<ConnectionPhase> { phaseSubject.publisher }

    private let videoSizeSubject: StateSubject<(Int, Int)?>
    var videoSize: AnyStatePublisher<(Int, Int)?> { videoSizeSubject.publisher }

    private let firstFrameSubject = StateSubject<Bool>(false)
    var firstFrame: AnyStatePublisher<Bool> { firstFrameSubject.publisher }

    private let statsSubject = StateSubject<StreamStats>(StreamStats())
    var stats: AnyStatePublisher<StreamStats> { statsSubject.publisher }

    private let deviceInfoSubject = StateSubject<DeviceInfo?>(nil)
    var deviceInfo: AnyStatePublisher<DeviceInfo?> { deviceInfoSubject.publisher }

    private let remoteClipboardSubject = StateSubject<String>("")
    var remoteClipboard: AnyStatePublisher<String> { remoteClipboardSubject.publisher }

    private let filesSubject = StateSubject<FileTransferClient?>(nil)
    var files: AnyStatePublisher<FileTransferClient?> { filesSubject.publisher }

    private let terminalSubject = StateSubject<TerminalChannel?>(nil)
    var terminal: AnyStatePublisher<TerminalChannel?> { terminalSubject.publisher }

    private let inputReadySubject = StateSubject<Bool>(false)
    var inputReady: AnyStatePublisher<Bool> { inputReadySubject.publisher }

    let input: InputProtocol
    let clipboard: ClipboardProtocol

    private var audioEnabled = true
    private var audioTrack: RTCAudioTrack?

    private static let connectTimeout: TimeInterval = 25
    private static let firstFrameTimeout: TimeInterval = 15
    private static let interruptGrace: TimeInterval = 8

    init(factory: RTCPeerConnectionFactory, httpFactory: HttpClientFactory,
         target: StreamTarget, projectionResumeKey: String?) {
        self.factory = factory
        self.httpFactory = httpFactory
        self.target = target
        self.projectionResumeKey = projectionResumeKey
        self.videoSizeSubject = StateSubject<(Int, Int)?>(target.displayHint)
        self.input = InputProtocol(sender: { [weak self] text in self?.sendInput(text) ?? false },
                                   viewOnly: { target.viewOnly })
        self.clipboard = ClipboardProtocol(sender: { [weak self] text in self?.sendClipboard(text) ?? false },
                                           enabled: { target.allowClipboard && !target.viewOnly })
        super.init()
        frameSink.owner = self
    }

    func setRenderer(_ renderer: RTCVideoRenderer?) {
        frameLock.lock(); self.renderer = renderer; frameLock.unlock()
    }

    func setAudioEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.audioEnabled = enabled
            self.audioTrack?.isEnabled = enabled
        }
    }

    // MARK: 生命周期
    func start(delay: TimeInterval = 0) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.doStart() }
    }

    private func doStart() {
        guard !closed else { return }
        phaseSubject.send(.signaling)
        connectTimer = schedule(seconds: Self.connectTimeout) { [weak self] in
            guard let self, !self.closed else { return }
            if self.phaseSubject.value != .connected {
                self.fail("连接超时，设备可能离线或网络受限", retryable: true)
            }
        }

        let client = SignalingClient(httpFactory: httpFactory, target: target, listener: self)
        self.signaling = client
        client.connect()
    }

    func close(endProjection: Bool = false) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            if endProjection, let key = self.projectionResumeKey {
                self.signaling?.send(SignalingProtocol.projectionEnd(self.target.deviceId, resumeKey: key))
            }
            self.teardown(.closed)
        }
    }

    /// 回调线程转投到会话线程
    private func post(_ block: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            block()
        }
    }

    private func fail(_ message: String, retryable: Bool, auth: Bool = false) {
        guard !closed else { return }
        teardown(.failed(message: message, retryable: retryable, authError: auth))
    }

    private func teardown(_ final: ConnectionPhase) {
        guard !closed else { return }
        closed = true
        [statsTimer, connectTimer, firstFrameTimer, interruptTimer].forEach { $0?.cancel() }
        signaling?.close(); signaling = nil
        frameLock.lock(); renderer = nil; frameLock.unlock()
        inputReadySubject.send(false)
        filesSubject.send(nil)
        terminalSubject.send(nil)
        // 先释放通道（native 仍存活），再关闭 PC
        (agentChannels + [fileChannel, adbChannel].compactMap { $0 }).forEach { $0.release() }
        agentChannels.removeAll()
        inputChannel = nil; clipboardChannel = nil; fileChannel = nil; adbChannel = nil
        audioTrack = nil
        pc?.close(); pc = nil
        phaseSubject.send(final)
    }

    private func schedule(seconds: TimeInterval, block: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: block)
        timer.resume()
        return timer
    }

    private func scheduleRepeating(seconds: TimeInterval, block: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + seconds, repeating: seconds)
        timer.setEventHandler(handler: block)
        timer.resume()
        return timer
    }

    // MARK: 输入发送（任意线程）
    private func sendInput(_ text: String) -> Bool { inputChannel?.send(text) ?? false }
    private func sendClipboard(_ text: String) -> Bool { clipboardChannel?.send(text) ?? false }

    deinit {
        [statsTimer, connectTimer, firstFrameTimer, interruptTimer].forEach { $0?.cancel() }
    }
}

// MARK: - SignalingClient.Listener
extension RtcSession: SignalingClient.Listener {
    func onOpen() {
        post { [weak self] in self?.phaseSubject.send(.waitingOffer) }
    }

    func onMessage(_ msg: SignalingMessage) {
        post { [weak self] in self?.handleSignaling(msg) }
    }

    func onClosed(error: ApiError?, httpCode: Int?) {
        post { [weak self] in
            guard let self else { return }
            if httpCode == 401 || httpCode == 403 {
                self.fail(self.target.isGuest ? "卡密已失效或访问密码错误" : "登录已失效，请重新登录",
                          retryable: false, auth: true)
            } else if case .untrustedCertificate(let info)? = error {
                self.fail(info.changed ? "服务器证书已变更" : "服务器证书不受信任", retryable: false)
            } else if self.phaseSubject.value == .connected {
                // 媒体走 P2P，信令断开不影响已建立的画面；仅记录
            } else {
                self.fail(error?.errorDescription ?? "信令连接已断开", retryable: true)
            }
        }
    }

    private func handleSignaling(_ msg: SignalingMessage) {
        switch msg {
        case .config(let servers):
            createPeerConnection(servers)
            signaling?.send(SignalingProtocol.requestOffer(target.deviceId,
                                                            options: ScrcpyOptions.build(target),
                                                            resumeKey: projectionResumeKey))
            phaseSubject.send(.waitingOffer)
        case .deviceInfo(let raw):
            let info = Parsers.deviceInfo(raw)
            deviceInfoSubject.send(info)
            if videoSizeSubject.value == nil, let d = info.primaryDisplay {
                videoSizeSubject.send((d.width, d.height))
            }
        case .projectionStatus(let state):
            if state == "waiting" {
                if phaseSubject.value != .waitingProjection {
                    phaseSubject.send(.waitingProjection)
                    connectTimer?.cancel()
                    connectTimer = schedule(seconds: 85) { [weak self] in
                        guard let self, !self.closed, self.phaseSubject.value != .connected else { return }
                        self.fail("等待手机确认超时，请重新发起请求", retryable: false)
                    }
                }
            } else {
                let message: String?
                switch state {
                case "rejected": message = "手机用户未同意共享屏幕"
                case "expired": message = "投屏请求已超时，请重试"
                case "busy": message = "手机正在处理其他协助请求"
                case "unattended_denied": message = "亮屏无人值守仅允许有设备权限的管理台账号连接"
                case "ended": message = "屏幕共享已结束，可重新请求"
                case "failed": message = "手机未能启动共享，请重试"
                default: message = nil
                }
                if let message { fail(message, retryable: false) }
            }
        case .offer(let sdp):
            onRemoteOffer(sdp)
        case .answer(let sdp):
            setRemoteDescription(sdp, type: .answer) { [weak self] in
                self?.post { self?.onRemoteSet() }
            }
        case .candidate(let c):
            addRemoteCandidate(c)
        case .error(let code, let message):
            let text = code == "SHARE_IN_USE" ? "该分享正被其他访客使用，单个分享同时仅允许一人在线" : message
            fail(text, retryable: code != "SHARE_IN_USE")
        case .pong, .other:
            break
        }
    }

    private func createPeerConnection(_ specs: [IceServerSpec]) {
        guard pc == nil else { return }
        let servers = specs.map { s in
            RTCIceServer(urlStrings: s.urls, username: s.username, credential: s.credential)
        }
        let config = RTCConfiguration()
        config.iceServers = servers
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.tcpCandidatePolicy = .enabled
        config.keyType = .ECDSA

        guard let p = factory.peerConnection(with: config,
                                             constraints: RTCMediaConstraints(mandatoryConstraints: nil,
                                                                               optionalConstraints: nil),
                                             delegate: self) else {
            fail("创建连接失败", retryable: true)
            return
        }
        pc = p
        // file-channel / adb-channel 必须在协商前由本端创建：
        // 部分 libwebrtc 版本对协商后新建的通道不回调 OPEN
        let ordered = RTCDataChannelConfiguration()
        ordered.isOrdered = true
        if let dc = p.dataChannel(forLabel: "file-channel", configuration: ordered) {
            let ch = SafeChannel(dc)
            fileChannel = ch
            filesSubject.send(FileTransferClient(channel: ch))
        }
        if let dc = p.dataChannel(forLabel: "adb-channel", configuration: RTCDataChannelConfiguration()) {
            let ch = SafeChannel(dc)
            adbChannel = ch
            let term = TerminalChannel { [weak ch] data in ch?.sendBytes(data) ?? false }
            ch.observe(message: { data, binary in
                if binary { term.receive(data) }
            })
            terminalSubject.send(term)
        }
    }

    private func onRemoteOffer(_ sdp: String) {
        guard let p = pc else { return }
        phaseSubject.send(.negotiating)
        setRemoteDescription(sdp, type: .offer) { [weak self] in
            guard let self else { return }
            self.onRemoteSet()
            p.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                if let error { self.post { self.fail("SDP 协商失败：\(error.localizedDescription)", retryable: true) }; return }
                guard let answer else { self.post { self.fail("SDP 协商失败：无法生成应答", retryable: true) }; return }
                p.setLocalDescription(answer) { error in
                    if let error { self.post { self.fail("SDP 协商失败：\(error.localizedDescription)", retryable: true) }; return }
                    self.post { self.signaling?.send(SignalingProtocol.answer(self.target.deviceId, sdp: answer.sdp)) }
                }
            }
        }
    }

    private func setRemoteDescription(_ sdp: String, type: RTCSdpType, done: @escaping () -> Void) {
        guard let p = pc else { return }
        let desc = RTCSessionDescription(type: type, sdp: sdp)
        p.setRemoteDescription(desc) { [weak self] error in
            guard let self else { return }
            if let error {
                self.post { self.fail("SDP 协商失败：\(error.localizedDescription)", retryable: true) }
                return
            }
            done()
        }
    }

    private func onRemoteSet() {
        remoteDescriptionSet = true
        guard let p = pc else { return }
        let pending = pendingCandidates
        pendingCandidates.removeAll()
        for c in pending { p.addIceCandidate(c) { _ in } }
    }

    private func addRemoteCandidate(_ c: CandidateSpec) {
        let ice = RTCIceCandidate(sdp: c.candidate,
                                  sdpMLineIndex: Int32(c.sdpMLineIndex),
                                  sdpMid: c.sdpMid ?? "0")
        if !remoteDescriptionSet { pendingCandidates.append(ice) }
        else { pc?.addIceCandidate(ice) { _ in } }
    }

    // MARK: - RTCPeerConnectionDelegate（WebRTC 线程 → queue）
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        post { [weak self] in
            guard let self else { return }
            let spec = CandidateSpec(sdpMid: candidate.sdpMid,
                                     sdpMLineIndex: Int(candidate.sdpMLineIndex),
                                     candidate: candidate.sdp)
            self.signaling?.send(SignalingProtocol.candidate(self.target.deviceId, c: spec))
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        post { [weak self] in
            guard let self else { return }
            switch newState {
            case .connected, .completed:
                self.onConnected()
            case .disconnected:
                if self.phaseSubject.value == .connected {
                    self.phaseSubject.send(.interrupted)
                    self.interruptTimer?.cancel()
                    self.interruptTimer = self.schedule(seconds: Self.interruptGrace) { [weak self] in
                        guard let self, !self.closed, self.phaseSubject.value == .interrupted else { return }
                        self.fail("网络中断", retryable: true)
                    }
                }
            case .failed:
                self.fail("网络穿透失败，请检查网络或配置 TURN 中继", retryable: true)
            default:
                break
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver,
                        streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track else { return }
        post { [weak self] in self?.attachTrack(track) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        let tracks: [RTCMediaStreamTrack] = stream.videoTracks + stream.audioTracks
        for track in tracks { post { [weak self] in self?.attachTrack(track) } }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        post { [weak self] in self?.onAgentChannel(dataChannel) }
    }

    private func onConnected() {
        interruptTimer?.cancel()
        connectTimer?.cancel()
        if phaseSubject.value != .connected { phaseSubject.send(.connected) }
        // 连通但迟迟没有画面：给出明确提示而不是无限转圈
        if firstFrameTimer == nil && !firstFrameSubject.value {
            firstFrameTimer = schedule(seconds: Self.firstFrameTimeout) { [weak self] in
                guard let self, !self.closed, !self.firstFrameSubject.value else { return }
                self.fail(self.target.isCamera
                          ? "云手机摄像头没有输出画面，摄像头可能被占用或不可用"
                          : "已连接但没有收到画面，设备编码器可能启动失败",
                          retryable: !self.target.isCamera)
            }
        }
        if statsTimer == nil {
            statsTimer = scheduleRepeating(seconds: 1) { [weak self] in
                guard let self, !self.closed, let p = self.pc else { return }
                p.statistics { [weak self] report in
                    guard let self, !self.closed else { return }
                    self.post { self.statsSubject.send(self.statsCalc.compute(report)) }
                }
            }
        }
    }

    private func attachTrack(_ track: RTCMediaStreamTrack) {
        guard attachedTracks.insert(track.trackId).inserted else { return }
        if let video = track as? RTCVideoTrack {
            video.addRenderer(frameSink)
        } else if let audio = track as? RTCAudioTrack {
            audioTrack = audio
            audio.isEnabled = audioEnabled
        }
    }

    fileprivate func onVideoFrame(_ frame: RTCVideoFrame) {
        let rotation = Int(frame.rotation.rawValue)
        let swapped = rotation == 90 || rotation == 270
        let w = Int(swapped ? frame.height : frame.width)
        let h = Int(swapped ? frame.width : frame.height)
        if w > 0 && h > 0 {
            let cur = videoSizeSubject.value
            if cur == nil || cur?.0 != w || cur?.1 != h { videoSizeSubject.send((w, h)) }
        }
        if !firstFrameSubject.value {
            firstFrameSubject.send(true)
            firstFrameTimer?.cancel(); firstFrameTimer = nil
        }
        frameLock.lock(); let r = renderer; frameLock.unlock()
        r?.renderFrame(frame)
    }

    private func onAgentChannel(_ dc: RTCDataChannel) {
        let ch = SafeChannel(dc)
        agentChannels.append(ch)
        switch ch.label {
        case "input-channel":
            inputChannel = ch
            ch.observe(state: { [weak self] state in
                self?.inputReadySubject.send(state == .open)
            })
            inputReadySubject.send(ch.isOpen)
        case "clipboard-channel":
            clipboardChannel = ch
            ch.observe(message: { [weak self] data, binary in
                guard !binary, let self,
                      let text = String(data: data, encoding: .utf8),
                      let value = self.clipboard.parseIncoming(text) else { return }
                self.remoteClipboardSubject.send(value)
            })
        default:
            break
        }
    }
}

// MARK: - 轻量状态容器（替代 Combine 的 CurrentValueSubject，便于纯 Swift 测试）
final class StateSubject<T>: ObservableObject {
    private let lock = NSLock()
    private var current: T
    private var subscribers: [(T) -> Void] = []
    let publisher: AnyStatePublisher<T>

    init(_ initial: T) {
        current = initial
        publisher = AnyStatePublisher(subject: self)
    }

    var value: T { lock.lock(); defer { lock.unlock() }; return current }

    func send(_ value: T) {
        lock.lock()
        current = value
        let snapshot = subscribers
        lock.unlock()
        snapshot.forEach { $0(value) }
    }

    func subscribe(_ handler: @escaping (T) -> Void) {
        lock.lock(); subscribers.append(handler); let cur = current; lock.unlock()
        handler(cur)
    }
}

struct AnyStatePublisher<T> {
    private weak var subject: StateSubject<T>?
    fileprivate init(subject: StateSubject<T>) { self.subject = subject }
    func subscribe(_ handler: @escaping (T) -> Void) { subject?.subscribe(handler) }
}
