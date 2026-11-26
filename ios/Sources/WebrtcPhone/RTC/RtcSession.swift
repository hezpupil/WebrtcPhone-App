import Foundation
import WebRTC
import AVFoundation

// 便捷埋点
private func trail(_ event: String) { Trail.mark(event) }

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
    let target: StreamTarget
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
    /// getStats 已弃用：报告的 ObjC 桥接层存在数据依赖性 SIGTRAP（详见 onConnected 注释）

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

    lazy var input: InputProtocol = InputProtocol(
        sender: { [weak self] text in self?.sendInput(text) ?? false },
        viewOnly: { [weak self] in self?.target.viewOnly ?? true }
    )
    lazy var clipboard: ClipboardProtocol = ClipboardProtocol(
        sender: { [weak self] text in self?.sendClipboard(text) ?? false },
        enabled: { [weak self] in
            guard let self else { return false }
            return self.target.allowClipboard && !self.target.viewOnly
        }
    )

    private var audioEnabled = true
    private var audioTrack: RTCAudioTrack?
    private var videoTrack: RTCVideoTrack?
    private var frameCount = 0
    /// 当前统计窗口内的帧数（frameLock 保护），用于自研 fps 统计
    private var secFrames = 0
    /// 最近一次发布的统计（保留上次尺寸/解码器信息，避免每秒抖动清零）
    private var lastStats = StreamStats()

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
        super.init()
        frameSink.owner = self
    }

    func setRenderer(_ renderer: RTCVideoRenderer?) {
        frameLock.lock()
        let old = self.renderer
        self.renderer = renderer
        frameLock.unlock()
        guard old !== renderer else { return }
        // 渲染器直接注册为 track sink（对齐 Android addSink），不经过中转
        queue.async { [weak self] in
            guard let self else { return }
            if let v = self.videoTrack {
                if let old, old !== renderer { v.remove(old) }
                if let renderer { v.add(renderer) }
            }
        }
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
        trail("rtc:start dev=\(target.deviceId) guest=\(target.isGuest)")
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
        Trail.mark("rtc:fail [\(message)] retryable=\(retryable)")
        teardown(.failed(message: message, retryable: retryable, authError: auth))
    }

    private func teardown(_ final: ConnectionPhase) {
        guard !closed else { return }
        closed = true
        trail("rtc:teardown phase=\(final)")
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
        videoTrack = nil
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
        post { [weak self] in trail("rtc:ws-open"); self?.phaseSubject.send(.waitingOffer) }
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
            trail("sig:config ice=\(servers.count)")
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
            trail("sig:offer len=\(sdp.count)")
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
        trail("pc:creating")
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
        trail("pc:created")
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

    private func onRemoteOffer(_ sdpRaw: String) {
        guard let p = pc else { return }
        trail("pc:offer-received")
        // 音频决策：WebRTC 在应用含音频的 answer 时会初始化音频模块（VPIO），
        // 需要麦克风权限——TrollStore/侧载环境 TCC 弹窗不显示，会永久卡死或 abort。
        // 权限未授予时从 SDP 剔除音频段，WebRTC 便完全不会初始化音频模块。
        let sdp: String
        if target.settings.audio && Self.micPermissionGranted {
            trail("audio:on")
            sdp = sdpRaw
        } else {
            trail(target.settings.audio ? "audio:downgrade-mic-permission" : "audio:off-by-setting")
            let cleaned = Self.stripAudioSections(sdpRaw)
            trail(cleaned == sdpRaw ? "audio:no-audio-in-offer" : "audio:stripped")
            sdp = cleaned
        }
        phaseSubject.send(.negotiating)
        setRemoteDescription(sdp, type: .offer) { [weak self] in
            guard let self else { return }
            trail("pc:remote-set")
            self.onRemoteSet()
            p.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { answer, error in
                if let error { self.post { self.fail("SDP 协商失败：\(error.localizedDescription)", retryable: true) }; return }
                guard let answer else { self.post { self.fail("SDP 协商失败：无法生成应答", retryable: true) }; return }
                trail("pc:answer-created")
                Self.trailAnswerVideoCodecs(answer.sdp)
                p.setLocalDescription(answer) { error in
                    if let error { self.post { self.fail("SDP 协商失败：\(error.localizedDescription)", retryable: true) }; return }
                    self.post { self.signaling?.send(SignalingProtocol.answer(self.target.deviceId, sdp: answer.sdp)); trail("sig:answer-sent") }
                }
            }
        }
    }

    /// 若麦克风权限从未询问，异步触发一次系统权限弹窗（不阻塞当前连接）；
    /// 授予后下次连接即可带上音频。TrollStore/侧载环境弹窗不出现，本次连接
    /// 仍按无音频降级进行，不会卡死。
    static func requestMicPermissionIfNeeded() {
        if #available(iOS 17.0, *) {
            guard AVAudioApplication.shared.recordPermission == .undetermined else { return }
            AVAudioApplication.requestRecordPermission { _ in }
        } else {
            guard AVAudioSession.sharedInstance().recordPermission == .undetermined else { return }
            AVAudioSession.sharedInstance().requestRecordPermission { _ in }
        }
    }

    /// 系统麦克风权限是否已授予（iOS 17 起用 AVAudioApplication）
    private static var micPermissionGranted: Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .granted
        }
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    /// 埋点 answer SDP 的视频编码器（诊断黑屏：看 H264 是否真的协商成功）
    private static func trailAnswerVideoCodecs(_ sdp: String) {
        var inVideo = false
        var lines: [String] = []
        for line in sdp.components(separatedBy: "\r\n") {
            if line.hasPrefix("m=") { inVideo = line.hasPrefix("m=video") }
            if inVideo {
                if line.hasPrefix("m=video") || (line.hasPrefix("a=rtpmap:") && (line.contains("H264") || line.contains("VP8") || line.contains("VP9") || line.contains("AV1"))) {
                    lines.append(line)
                }
            }
        }
        trail("sdp:video-codecs " + lines.joined(separator: " | "))
    }

    /// 从 SDP 中移除音频 m-line 段（含 BUNDLE 清理），用于无音频降级连接。
    private static func stripAudioSections(_ sdp: String) -> String {        guard sdp.contains("m=audio") else { return sdp }
        let lines = sdp.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        var audioMids = Set<String>()
        var skip = false
        for line in lines {
            if line.hasPrefix("m=") { skip = line.hasPrefix("m=audio") }
            if skip, line.hasPrefix("a=mid:") {
                audioMids.insert(String(line.dropFirst(6)))
            }
        }
        var out: [String] = []
        skip = false
        for line in lines {
            if line.hasPrefix("m=") { skip = line.hasPrefix("m=audio") }
            if skip { continue }
            if line.hasPrefix("a=group:BUNDLE") {
                let kept = line.split(separator: " ").filter { !audioMids.contains(String($0)) }
                out.append(kept.joined(separator: " "))
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\r\n") + "\r\n"
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
        for c in pending { p.add(c) { _ in } }
    }

    private func addRemoteCandidate(_ c: CandidateSpec) {
        let ice = RTCIceCandidate(sdp: c.candidate,
                                  sdpMLineIndex: Int32(c.sdpMLineIndex),
                                  sdpMid: c.sdpMid ?? "0")
        if !remoteDescriptionSet { pendingCandidates.append(ice) }
        else { pc?.add(ice) { _ in } }
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
                trail("ice:connected")
                self.onConnected()
            case .disconnected:
                trail("ice:disconnected")
                if self.phaseSubject.value == .connected {
                    self.phaseSubject.send(.interrupted)
                    self.interruptTimer?.cancel()
                    self.interruptTimer = self.schedule(seconds: Self.interruptGrace) { [weak self] in
                        guard let self, !self.closed, self.phaseSubject.value == .interrupted else { return }
                        self.fail("网络中断", retryable: true)
                    }
                }
            case .failed:
                trail("ice:failed")
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
            // 自研统计：fps 来自帧回调计数、尺寸来自视频流，完全不触碰 getStats。
            // 背景：getStats 报告的 ObjC 桥接层在特定报告内容下触发 SIGTRAP（第 4~6 个
            // 回调时数据依赖性崩溃，dSYM 符号化 + 全量数值防御均无法根除），故移除。
            var statTicks = 0
            statsTimer = scheduleRepeating(seconds: 1) { [weak self] in
                guard let self, !self.closed else { return }
                self.frameLock.lock()
                let fps = self.secFrames
                self.secFrames = 0
                self.frameLock.unlock()
                var s = self.lastStats
                s.fps = fps
                if let size = self.videoSizeSubject.value {
                    s.width = size.0
                    s.height = size.1
                }
                if fps == 0 { s.bitrateBps = 0 }
                self.lastStats = s
                self.statsSubject.send(s)
                statTicks += 1
                if statTicks % 3 == 0 {
                    trail("stats: fps=\(s.fps) \(s.width)x\(s.height)")
                }
            }
        }
    }

    private func attachTrack(_ track: RTCMediaStreamTrack) {
        guard attachedTracks.insert(track.trackId).inserted else { return }
        if let video = track as? RTCVideoTrack {
            trail("track:attached video id=\(track.trackId)")
            videoTrack = video
            video.add(frameSink)
            frameLock.lock(); let r = self.renderer; frameLock.unlock()
            if let r { video.add(r) }
        } else if let audio = track as? RTCAudioTrack {
            trail("track:attached audio")
            audioTrack = audio
            audio.isEnabled = audioEnabled
        }
    }

    fileprivate func onVideoFrame(_ frame: RTCVideoFrame) {
        frameCount += 1
        frameLock.lock(); secFrames += 1; frameLock.unlock()
        if frameCount == 1 || frameCount % 300 == 0 {
            trail("frame:cb n=\(frameCount) \(frame.width)x\(frame.height) rot=\(Int(frame.rotation.rawValue))")
        }
        let rotation = Int(frame.rotation.rawValue)
        let swapped = rotation == 90 || rotation == 270
        let w = Int(swapped ? frame.height : frame.width)
        let h = Int(swapped ? frame.width : frame.height)
        if w > 0 && h > 0 {
            let cur = videoSizeSubject.value
            if cur == nil || cur?.0 != w || cur?.1 != h {
                if firstFrameSubject.value { trail("video:resize \(w)x\(h)") }
                videoSizeSubject.send((w, h))
            }
        }
        if !firstFrameSubject.value {
            trail("video:first \(w)x\(h) rot=\(rotation)")
            firstFrameSubject.send(true)
            firstFrameTimer?.cancel(); firstFrameTimer = nil
        }
    }

    private func onAgentChannel(_ dc: RTCDataChannel) {
        let ch = SafeChannel(dc)
        agentChannels.append(ch)
        trail("dc:open \(ch.label)")
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

    init(_ initial: T) { current = initial }

    /// 每次返回一个持有本 subject 的轻量句柄；subject 由 RtcSession 强持有，无循环引用。
    var publisher: AnyStatePublisher<T> { AnyStatePublisher(subject: self) }

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
    private let subject: StateSubject<T>
    fileprivate init(subject: StateSubject<T>) { self.subject = subject }
    var value: T { subject.value }
    func subscribe(_ handler: @escaping (T) -> Void) { subject.subscribe(handler) }
}
