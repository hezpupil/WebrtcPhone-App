import Foundation
import VideoToolbox
import CoreMedia

/// WS 备用投屏会话：通过 /connect_client 收 H.264 裸流（PREV 帧），VideoToolbox 解码。
/// 对齐 Android 端 WsStreamSession.kt（MediaCodec 版本）。
/// 仅支持视频 + 输入（touch/key/text/scroll 经 group_control_event）；无音频/文件/终端。
@MainActor
final class WsStreamSession: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .signaling
    @Published private(set) var videoSize: (Int, Int)?
    @Published private(set) var firstFrame = false
    @Published private(set) var stats = StreamStats()

    private let target: StreamTarget
    private let httpFactory: HttpClientFactory

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var delegate: WebSocketSessionDelegate?
    private var closed = false

    private let decodeQueue = DispatchQueue(label: "ws.decode")
    private var decoder: H264Decoder?
    private var gotKeyFrame = false
    private var frameCount: Int64 = 0
    private var byteCount: Int64 = 0
    private var lastStatsAt = Date()
    private var statsTimer: DispatchSourceTimer?

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
        self.decoder = H264Decoder { [weak self] size in
            guard let self else { return }
            Task { @MainActor in
                if !self.firstFrame {
                    self.firstFrame = true
                    self.phase = .connected
                    if let s = size, self.videoSize == nil { self.videoSize = s }
                }
                self.frameCount += 1
            }
        }
    }

    func start() {
        guard !closed else { return }
        phase = .signaling
        let ep = target.endpoint
        var components = URLComponents(string: ep.wsUrl("/connect_client"))!
        var headers: [String: String] = [:]
        switch target.auth {
        case .user(let token): headers["Authorization"] = "Bearer \(token)"
        case .share(let t, let p):
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "share_token", value: t))
            if !p.isEmpty { items.append(URLQueryItem(name: "share_pwd", value: p)) }
            components.queryItems = items
        }
        var request = URLRequest(url: components.url!)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (session, delegate) = httpFactory.newWebSocketSession(for: ep)
        self.session = session
        self.delegate = delegate
        delegate.onOpen = { [weak self] in
            guard let self, !self.closed else { return }
            Task { @MainActor in
                self.phase = .waitingOffer
                let s = self.target.settings
                let bps = max(1, s.bitrateMbps) * 1_000_000
                self.sendText(WsProtocol.startPreview(deviceId: self.target.deviceId, fps: s.maxFps,
                                                       maxSize: s.maxSize, bitrateBps: bps, stayAwake: true))
                self.phase = .negotiating
            }
        }
        delegate.onFailure = { [weak self] error, code in
            guard let self, !self.closed else { return }
            Task { @MainActor in
                let auth = code == 401 || code == 403
                self.phase = .failed(message: auth ? "登录已失效" : "连接失败：\(error.localizedDescription)",
                                    retryable: !auth, authError: auth)
            }
        }
        delegate.onClose = { [weak self] _, _ in
            guard let self, !self.closed else { return }
            Task { @MainActor in self.phase = .failed("连接已断开", retryable: true) }
        }
        let wsTask = session.webSocketTask(with: request)
        self.task = wsTask
        wsTask.resume()
        receiveLoop()

        statsTimer = DispatchSource.makeTimerSource(queue: decodeQueue)
        statsTimer?.schedule(deadline: .now() + 1, repeating: 1)
        statsTimer?.setEventHandler { [weak self] in self?.tickStats() }
        statsTimer?.resume()
    }

    func close() {
        guard !closed else { return }
        closed = true
        statsTimer?.cancel(); statsTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel(); session = nil
        delegate = nil
        decoder?.reset()
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
                    if let frame = WsProtocol.parsePrev(data) {
                        if !frame.deviceId.isEmpty && frame.deviceId != self.target.deviceId { return }
                        self.byteCount += Int64(frame.nalu.count)
                        self.feed(frame.nalu, isKey: frame.isKey)
                    }
                case .string:
                    break
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure:
                Task { @MainActor in
                    if !self.closed { self.phase = .failed("连接已断开", retryable: true) }
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
        }
    }
}

/// VideoToolbox H.264 解码器：接收 Annex-B NALU（SPS/PPS/IDR），输出首帧尺寸。
private final class H264Decoder {
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private let firstFrame: ((CGSize?) -> Void)?
    private var reported = false

    init(firstFrame: @escaping (CGSize?) -> Void) { self.firstFrame = firstFrame }

    func decode(_ annexB: Data, isKey: Bool) {
        let nalus = splitAnnexB(annexB)
        for nalu in nalus {
            guard nalu.count > 4 else { continue }
            let type = nalu[4] & 0x1F
            if type == 7 { sps = nalu; continue }
            if type == 8 { pps = nalu; continue }
        }
        if session == nil, let sps, let pps {
            let status = sps.withUnsafeBytes { sp in
                pps.withUnsafeBytes { pp in
                    CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: nil,
                        parameterSetCount: 2,
                        parameterSetPointers: [sp.baseAddress!, pp.baseAddress!],
                        parameterSetSizes: [sps.count, pps.count],
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &formatDesc
                    )
                }
            }
            guard status == noErr, let formatDesc else { return }
            var attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey: Int(CMVideoFormatDescriptionGetDimensions(formatDesc).width),
                kCVPixelBufferHeightKey: Int(CMVideoFormatDescriptionGetDimensions(formatDesc).height),
            ]
            let cb: VTDecompressionOutputCallbackRecord = VTDecompressionOutputCallbackRecord(
                decompressionOutputCallback: { _, _, status, _, imageBuffer, _, _ in
                    guard status == noErr, let imageBuffer else { return }
                    _ = imageBuffer
                },
                decompressionOutputRefCon: nil
            )
            VTDecompressionSessionCreate(allocator: nil, formatDescription: formatDesc,
                                         decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
                                         outputCallback: &cb, decompressionSessionOut: &session)
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
        if !reported, let formatDesc {
            reported = true
            let d = CMVideoFormatDescriptionGetDimensions(formatDesc)
            firstFrame(CGSize(width: Int(d.width), height: Int(d.height)))
        }
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
            else if i + 4 < b.count, b[i] == 0 && b[i+1] == 0 && b[i+2] == 0 && b[i+3] == 1 { starts.append(i); i += 4 }
            else { i += 1 }
        }
        for (idx, s) in starts.enumerated() {
            let payloadStart = s + (b[s+2] == 1 ? 3 : 4)
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

private final class AtomicInt64WS {
    private let lock = NSLock()
    private var value: Int64
    init(_ v: Int64 = 0) { value = v }
    func next() -> Int64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
