import Foundation

/// getStats 报告解析器（字符串防御版）。
///
/// 输入来自 LegacyStatsBridge（ObjC 直调 + 纯字符串转换），本类型在 Swift 里
/// 只允许一种数值转换路径：Double(String) → isFinite 检查 → 显式范围检查 →
/// Int()。不存在任何隐式 Double→Int / NSNumber.int64Value 转换——那正是当年
/// SIGTRAP 的根源（extractVideo+1576 的 brk 反汇编确认）。
/// 差分算法对齐 Android 端 StatsCalculator.compute()。
struct LegacyStatsParser {
    private var lastTs = 0.0
    private var lastBytes = 0.0
    private var lastFramesDecoded = 0.0
    private var lastDecodeTime = 0.0
    private var lastJbDelay = 0.0
    private var lastJbEmitted = 0.0
    private var lastPacketsLost = 0.0
    private var lastPacketsReceived = 0.0

    /// 报告类型别名：statsId -> { type, values }
    typealias Report = [String: [String: String]]

    // MARK: - 唯一数值转换入口（全部 static，调用一律 Self.xxx）

    private static func num(_ s: String?) -> Double {
        guard let s, !s.isEmpty, let d = Double(s), d.isFinite, d.magnitude <= 1e15 else { return 0 }
        return d
    }

    /// Double → Int 唯一直转入口：isFinite + 非负 + 上限三重检查后人工转换
    private static func idbl(_ d: Double) -> Int {
        d.isFinite && d >= 0 && d <= 9e15 ? Int(d) : 0
    }

    private static func int(_ s: String?) -> Int {
        idbl(num(s))
    }

    private static func str(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    // MARK: - 候选对（RTT / 候选类型 / 协议）

    private static func extractPair(_ report: Report) -> (rtt: Double, cand: String, proto: String) {
        var pair: [String: String]?
        var fallback: [String: String]?
        for (_, st) in report {
            guard st["type"] == "candidate-pair" else { continue }
            guard str(st["state"]) == "succeeded" else { continue }
            let nominated = st["nominated"] == "true" || st["nominated"] == "1"
            let selected = st["selected"] == "true" || st["selected"] == "1"
            if nominated || selected { pair = st; break }
            if fallback == nil { fallback = st }
        }
        guard let m = pair ?? fallback else { return (0, "", "") }
        let rtt = num(m["currentRoundTripTime"])
        var cand = ""
        var proto = ""
        if let localId = str(m["localCandidateId"]), let local = report[localId] {
            cand = str(local["candidateType"]) ?? ""
            proto = str(local["protocol"]) ?? ""
        }
        if cand == "relay" || cand.isEmpty,
           let remoteId = str(m["remoteCandidateId"]),
           let remote = report[remoteId], remote["candidateType"] == "relay" {
            cand = "relay"
        }
        return (rtt, cand, proto)
    }

    // MARK: - 视频入站流差分（实例方法：读写差分状态）

    private mutating func extractVideo(_ report: Report) -> StreamStats? {
        var video: [String: String]?
        for (_, st) in report {
            guard st["type"] == "inbound-rtp" else { continue }
            if Self.str(st["kind"]) == "video" || Self.str(st["mediaType"]) == "video" {
                video = st
                break
            }
        }
        guard let m = video else { return nil }

        let ts = Self.num(m["timestamp_us"]) / 1_000_000.0
        let bytes = Self.num(m["bytesReceived"])
        let framesDecoded = Self.num(m["framesDecoded"])
        let decodeTime = Self.num(m["totalDecodeTime"])
        let jbDelay = Self.num(m["jitterBufferDelay"])
        let jbEmitted = Self.num(m["jitterBufferEmittedCount"])
        let lost = Self.num(m["packetsLost"])
        let recv = Self.num(m["packetsReceived"])

        var out = StreamStats()
        out.fps = Self.int(m["framesPerSecond"])
        out.framesDropped = Int64(Self.int(m["framesDropped"]))
        out.width = Self.int(m["frameWidth"])
        out.height = Self.int(m["frameHeight"])
        out.jitterMs = Self.idbl(Self.num(m["jitter"]) * 1000)

        let dt = ts > lastTs ? ts - lastTs : 0
        let dBytes = bytes > lastBytes ? bytes - lastBytes : 0
        if lastTs > 0 && dt > 0 {
            out.bitrateBps = Int64(Self.idbl(dBytes * 8 / dt))
        }
        let dFrames = framesDecoded > lastFramesDecoded ? framesDecoded - lastFramesDecoded : 0
        let dTime = decodeTime > lastDecodeTime ? decodeTime - lastDecodeTime : 0
        if dFrames > 0 {
            out.decodeMs = Self.idbl(dTime / dFrames * 1000)
        }
        let dEmitted = jbEmitted > lastJbEmitted ? jbEmitted - lastJbEmitted : 0
        let dJb = jbDelay > lastJbDelay ? jbDelay - lastJbDelay : 0
        if dEmitted > 0 {
            out.jitterBufferMs = Self.idbl(dJb / dEmitted * 1000)
        }
        let dLost = lost > lastPacketsLost ? lost - lastPacketsLost : 0
        let dRecv = recv > lastPacketsReceived ? recv - lastPacketsReceived : 0
        if dLost + dRecv > 0 {
            out.packetLossPct = Float(Self.idbl(dLost * 100 / (dLost + dRecv)))
        }

        lastTs = ts; lastBytes = bytes; lastFramesDecoded = framesDecoded
        lastDecodeTime = decodeTime; lastJbDelay = jbDelay; lastJbEmitted = jbEmitted
        lastPacketsLost = lost; lastPacketsReceived = recv

        if let codecId = Self.str(m["codecId"]), let c = report[codecId],
           let mime = Self.str(c["mimeType"]) {
            out.codec = mime.split(separator: "/").last.map(String.init) ?? ""
        }
        out.decoder = Self.str(m["decoderImplementation"]) ?? ""
        return out
    }

    // MARK: - 入口（每 2 秒调用一次）

    mutating func compute(_ report: Report) -> StreamStats {
        var out = StreamStats()
        let pair = Self.extractPair(report)
        out.rttMs = Self.idbl(pair.rtt * 1000)
        out.candidateType = pair.cand
        out.protocolName = pair.proto
        if let v = extractVideo(report) {
            out.fps = v.fps
            out.bitrateBps = v.bitrateBps
            out.width = v.width
            out.height = v.height
            out.packetLossPct = v.packetLossPct
            out.jitterMs = v.jitterMs
            out.decodeMs = v.decodeMs
            out.jitterBufferMs = v.jitterBufferMs
            out.framesDropped = v.framesDropped
            if !v.codec.isEmpty { out.codec = v.codec }
            out.decoder = v.decoder
        }
        return out
    }
}
