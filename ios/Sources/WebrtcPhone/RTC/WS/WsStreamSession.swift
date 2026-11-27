import Foundation
import VideoToolbox
import CoreMedia

/// WS 备用投屏会话：通过 /connect_client 收 H.264 裸流（PREV 帧），VideoToolbox 解码到
/// CVPixelBuffer，经 H264FrameRenderer（MTKView）上屏。对齐 Android 端 WsStreamSession.kt。
/// 仅支持视频 + 输入（touch/key/text/scroll 经 group_control_event）；无音频/文件/终端。
@MainActor
final class WsStreamSession: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .signaling
    @Published private(set) var videoSize: (Int, Int)?
    @Published private(set) var firstFrame = false
    @Published private(set) var stats = StreamStats()

    let target: StreamTarget
    private let httpFactory: HttpClientFactory

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var delegate: WebSocketSessionDelegate?
    private var pingTimer: DispatchSourceTimer?
    private var closed = false

    private let decodeQueue = DispatchQueue(label: "ws.decode")
    private var decoder: H264Decoder?
    private var gotKeyFrame = false
    // trail 观测（跨线程只作趋势记录，不需精确）
    private var gotAnyBin = false
    private var gotAnyText = false
    private var skipCount = 0
    private var badBinCount = 0
    private var frameCount: Int64 = 0
    private var byteCount: Int64 = 0
    private var lastStatsAt = Date()
    private var statsTimer: DispatchSourceTimer?

    /// 解码线程回调：每帧交付 BGRA CVPixelBuffer（由 H264FrameRenderer.display 消费）
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let idSeq = AtomicInt64WS(0)

    /// 输入：包进 group_control_event 下发同一条 WS
    lazy var input: InputProtocol = InputProtocol(
        sender: { [weak self] json in self?.sendControl(json) ?? false },
        viewOnly: { [weak self] in self?.target.viewOnly ?? true }
    )

    init(target: StreamTarget, httpFactory: HttpClientFactory) {
        self.target = target
        self.httpFactory = httpFactory
        self.videoSize = target.displayHint
    }

    func start() {
        guard !closed else { return }
        phase = .signaling
        // 首帧驱动：VT 输出回调（decodeQueue）→ 主线程状态更新 + 渲染器交付
        decoder = H264Decoder { [weak self] pixelBuffer, size in
            guard let self else { return }
            self.onFrame?(pixelBuffer)
            Task { @MainActor in
                if !self.firstFrame {
                    self.firstFrame = true
                    self.phase = .connected
                    Trail.mark("ws:first-frame")
                }
                if let s = size { self.videoSize = (Int(s.width), Int(s.height)) }
                self.frameCount += 1
            }
        }
        let ep = target.endpoint
        var components = URLComponents(string: ep.wsUrl("/connect_client"))!
        var headers: [String: String] = [:]
        switch target.auth {
        case .user(let token):
            // 鉴权走 query token（对齐 Android "?token=$token"，web-app 系服务端从
            // query 读身份；握手成功但身份缺失时服务端不推流，表现为卡 negotiating）
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "token", value: token))
            components.queryItems = items
            headers["Authorization"] = "Bearer \(token)"
        case .share(let t, let p):
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "share_token", value: t))
            if !p.isEmpty { items.append(URLQueryItem(name: "share_pwd", value: p)) }
            components.queryItems = items
        }
        var request = URLRequest(url: components.url!)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        Trail.mark("ws:connect dev=\(target.deviceId)")

        let (session, delegate) = httpFactory.newWebSocketSession(for: ep)
        self.session = session
        self.delegate = delegate
        delegate.onOpen = { [weak self] in
            guard let self, !self.closed else { return }
            Trail.mark("ws:open")
            Task { @MainActor in
                self.phase = .waitingOffer
                let s = self.target.settings
                let bps = max(1, s.bitrateMbps) * 1_000_000
                let msg = WsProtocol.startPreview(deviceId: self.target.deviceId, fps: s.maxFps,
                                                  maxSize: s.maxSize, bitrateBps: bps, stayAwake: true)
                self.sendText(msg)
                Trail.mark("ws:start-sent fps=\(s.maxFps) size=\(s.maxSize) bps=\(bps)")
                self.phase = .negotiating
            }
        }
        delegate.onFailure = { [weak self] error, code in
            guard let self, !self.closed else { return }
            Trail.mark("ws:failure http=\(code ?? -1) err=\(error.localizedDescription)")
            Task { @MainActor in
                let auth = code == 401 || code == 403
                self.phase = .failed(message: auth ? "登录已失效" : "连接失败：\(error.localizedDescription)",
                                    retryable: !auth, authError: auth)
            }
        }
        delegate.onClose = { [weak self] _, _ in
            guard let self, !self.closed else { return }
            Trail.mark("ws:close")
            Task { @MainActor in self.phase = .failed(message: "连接已断开", retryable: true) }
        }
        let wsTask = session.webSocketTask(with: request)
        // 服务端大码流关键帧可能超默认 1MB 上限（URLSessionWebSocketTask 默认按此截断报错）
        wsTask.maximumMessageSize = 8 * 1024 * 1024
        self.task = wsTask
        wsTask.resume()
        receiveLoop()
        startPing(wsTask)

        statsTimer = DispatchSource.makeTimerSource(queue: decodeQueue)
        statsTimer?.schedule(deadline: .now() + 1, repeating: 1)
        statsTimer?.setEventHandler { [weak self] in self?.tickStats() }
        statsTimer?.resume()
    }

    /// 协议级 ping 心跳（对齐 Android OkHttp pingInterval 25s）：维持代理/NAT 表项，
    /// 防止无媒体流期间的空闲超时断开
    private func startPing(_ wsTask: URLSessionWebSocketTask) {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: decodeQueue)
        timer.schedule(deadline: .now() + 25, repeating: 25)
        timer.setEventHandler { [weak wsTask] in
            wsTask?.sendPing(pongReceiveHandler: { _ in })
        }
        timer.resume()
        pingTimer = timer
    }

    func close() {
        guard !closed else { return }
        closed = true
        pingTimer?.cancel(); pingTimer = nil
        statsTimer?.cancel(); statsTimer = nil
        // 对齐 Android：先发 stop_preview 让 agent 停推（发送失败不影响关闭流程）
        sendText(WsProtocol.stopPreview(target.deviceId))
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel(); session = nil
        delegate = nil
        onFrame = nil
        let dec = decoder
        decodeQueue.async { dec?.reset() }
        if !phase.isTerminal { phase = .closed }
    }

    func setAudioEnabled(_ enabled: Bool) {} // WS 模式无音频

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    if !self.gotAnyBin {
                        self.gotAnyBin = true
                        Trail.mark("ws:first-bin len=\(data.count)")
                    }
                    if let frame = WsProtocol.parsePrev(data) {
                        // 等关键帧期间的丢弃记录（前 3 次，避免刷爆 trail）
                        if !self.gotKeyFrame, !frame.isKey, self.skipCount < 3 {
                            self.skipCount += 1
                            let nal = frame.nalu.count > 4 ? Int(frame.nalu[4] & 0x1F) : -1
                            Trail.mark("ws:skip-nonkey nal=\(nal)")
                        }
                        if !frame.deviceId.isEmpty && frame.deviceId != self.target.deviceId { return }
                        self.byteCount += Int64(frame.nalu.count)
                        self.feed(frame.nalu, isKey: frame.isKey)
                    } else if self.badBinCount < 3 {
                        self.badBinCount += 1
                        Trail.mark("ws:bad-bin len=\(data.count)")
                    }
                case .string(let text):
                    if !self.gotAnyText {
                        self.gotAnyText = true
                        Trail.mark("ws:first-text \(text.prefix(120))")
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                Trail.mark("ws:recv-fail \(error.localizedDescription)")
                Task { @MainActor in
                    if !self.closed { self.phase = .failed(message: "连接已断开", retryable: true) }
                }
            }
        }
    }

    private func sendText(_ text: String) {
        task?.send(.string(text)) { _ in }
    }

    private func sendControl(_ json: String) -> Bool {
        guard let event = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return false }
        sendText(WsProtocol.groupControlEvent(target.deviceId, event: event))
        return task != nil
    }

    private func feed(_ nalu: Data, isKey: Bool) {
        decodeQueue.async { [weak self] in
            guard let self, !self.closed else { return }
            if !self.gotKeyFrame {
                guard isKey else { return }
                self.gotKeyFrame = true
            }
            self.decoder?.decode(nalu, isKey: isKey)
        }
    }

    private func tickStats() {
        let now = Date()
        let dt = max(1, now.timeIntervalSince(lastStatsAt))
        let frames = frameCount; frameCount = 0
        let bytes = byteCount; byteCount = 0
        lastStatsAt = now
        let size = videoSize
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stats.fps = Int(Double(frames) / dt)
            self.stats.bitrateBps = Int64(Double(bytes) * 8 / dt)
            self.stats.width = size?.0 ?? 0
            self.stats.height = size?.1 ?? 0
            self.stats.codec = "H.264"
            self.stats.protocolName = "WS/TCP"
        }
    }
}

/// VideoToolbox H.264 解码器：接收 Annex-B NALU（SPS/PPS/IDR），
/// 输出 BGRA CVPixelBuffer（含 SPS/PPS 尺寸）。decode 仅在单一线程调用。
private final class H264Decoder {
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var reported = false
    private let onFrame: (CVPixelBuffer, CGSize?) -> Void

    init(onFrame: @escaping (CVPixelBuffer, CGSize?) -> Void) {
        self.onFrame = onFrame
    }

    func decode(_ annexB: Data, isKey: Bool) {
        let nalus = splitAnnexB(annexB)
        for nalu in nalus {
            guard nalu.count > 4 else { continue }
            let type = nalu[4] & 0x1F
            if type == 7 { sps = nalu; continue }
            if type == 8 { pps = nalu; continue }
        }
        if session == nil, let sps, let pps {
            createSession(sps: sps, pps: pps)
        }
        guard let session else { return }
        let avcc = toAVCC(nalus)
        guard !avcc.isEmpty else { return }
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: avcc.count,
                                           blockAllocator: nil, customBlockSource: nil,
                                           offsetToData: 0, dataLength: avcc.count, flags: 0,
                                           blockBufferOut: &block)
        guard let block else { return }
        avcc.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true,
                             makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc,
                             sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                             sampleSizeEntryCount: 1, sampleSizeArray: [avcc.count], sampleBufferOut: &sample)
        guard let sample else { return }
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                          frameRefcon: nil, infoFlagsOut: nil)
    }

    /// 创建 VT 会话。输出回调是 C 函数指针（不能捕获上下文），self 经 refcon 传入。
    private func createSession(sps: Data, pps: Data) {
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        let sizes = [sps.count, pps.count]
        var fmt: CMVideoFormatDescription?
        let status: OSStatus = spsBytes.withUnsafeBufferPointer { sp in
            ppsBytes.withUnsafeBufferPointer { pp in
                let pointers: [UnsafePointer<UInt8>] = [sp.baseAddress!, pp.baseAddress!]
                return pointers.withUnsafeBufferPointer { pbuf in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil,
                        parameterSetCount: 2,
                        parameterSetPointers: pbuf.baseAddress!,
                        parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &fmt
                    )
                }
            }
        }
        guard status == noErr, let format = fmt else {
            Trail.mark("h264d:fmt-failed \(status)")
            return
        }
        formatDesc = format
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: Int(dims.width),
            kCVPixelBufferHeightKey: Int(dims.height),
        ]
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var cb = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: h264OutputCallback,
            decompressionOutputRefCon: refcon
        )
        var out: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                              decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary,
                                              outputCallback: &cb, decompressionSessionOut: &out)
        guard st == noErr, let s = out else {
            Trail.mark("h264d:session-failed \(st)")
            return
        }
        session = s
    }

    /// 输出回调（VT 内部线程）：有效帧 → onFrame（携带 SPS 尺寸提示，仅首次）
    fileprivate func emit(_ imageBuffer: CVImageBuffer) {
        var size: CGSize?
        if !reported, let formatDesc {
            reported = true
            let d = CMVideoFormatDescriptionGetDimensions(formatDesc)
            size = CGSize(width: Int(d.width), height: Int(d.height))
        }
        onFrame(imageBuffer, size)
    }

    func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; formatDesc = nil; sps = nil; pps = nil; reported = false
    }

    private func splitAnnexB(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var result: [Data] = []
        var starts: [Int] = []
        var i = 0
        while i + 3 < b.count {
            if b[i] == 0 && b[i+1] == 0 && b[i+2] == 1 { starts.append(i); i += 3 }
            else { i += 1 }
        }
        for (idx, s) in starts.enumerated() {
            let payloadStart = s + 3
            let end = idx + 1 < starts.count ? starts[idx+1] : b.count
            if end > payloadStart { result.append(Data(b[payloadStart..<end])) }
        }
        return result
    }

    private func toAVCC(_ nalus: [Data]) -> Data {
        var out = Data()
        for n in nalus {
            var len = UInt32(n.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(n)
        }
        return out
    }
}

/// C 函数指针输出回调（VT 内部线程）：有效帧 → emit（CVPixelBuffer；丢弃/出错时忽略）
private func h264OutputCallback(_ refcon: UnsafeMutableRawPointer?,
                                _ sourceFrameRefCon: UnsafeMutableRawPointer?,
                                _ status: OSStatus,
                                _ infoFlags: VTDecodeInfoFlags,
                                _ imageBuffer: CVImageBuffer?,
                                _ pts: CMTime,
                                _ duration: CMTime) {
    guard status == noErr, let imageBuffer, let refcon else { return }
    if infoFlags.contains(.frameDropped) { return }
    Unmanaged<H264Decoder>.fromOpaque(refcon).takeUnretainedValue().emit(imageBuffer)
}

private final class AtomicInt64WS {
    private let lock = NSLock()
    private var value: Int64
    init(_ v: Int64 = 0) { value = v }
    func next() -> Int64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
