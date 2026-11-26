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

    // MARK: - 唯一数值转换入口

    private static func num(_ s: String?) -> Double {
        guard let s, !s.isEmpty, let d = Double(s), d.isFinite, d.magnitude <= 1e15 else { return 0 }
        return d
    }

    private static func int(_ s: String?) -> Int {
        id(num(s))
    }

    /// Double → Int 唯一直转入口：isFinite + 非负 + 上限三重检查后人工转换
    private static func id(_ d: Double) -> Int {
        d.isFinite && d >= 0 && d <= 9e15 ? Int(d) : 0
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
            let m = st
            guard str(m["state"]) == "succeeded" else { continue }
            let nominated = m["nominated"] == "true" || m["nominated"] == "1"
            let selected = m["selected"] == "true" || m["selected"] == "1"
            if nominated || selected { pair = m; break }
            if fallback == nil { fallback = m }
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

    // MARK: - 视频入站流差分

    private static func videoEntry(_ report: Report) -> [String: String]? {
        for (_, st) in report {
            guard st["type"] == "inbound-rtp" else { continue }
            if str(st["kind"]) == "video" || str(st["mediaType"]) == "video" { return st }
        }
        return nil
    }

    private static func extractVideo(_ report: Report) -> StreamStats? {
        guard let video = videoEntry(report) else { return nil }
        let m = video
        let ts = num(m["timestamp_us"]) / 1_000_000.0
        let bytes = num(m["bytesReceived"])
        let framesDecoded = num(m["framesDecoded"])
        let decodeTime = num(m["totalDecodeTime"])
        let jbDelay = num(m["jitterBufferDelay"])
        let jbEmitted = num(m["jitterBufferEmittedCount"])
        let lost = num(m["packetsLost"])
        let recv = num(m["packetsReceived"])

        var out = StreamStats()
        out.fps = int(m["framesPerSecond"])
        out.framesDropped = Int64(int(m["framesDropped"]))
        out.width = int(m["frameWidth"])
        out.height = int(m["frameHeight"])
        out.jitterMs = id(num(m["jitter"]) * 1000)

        let dt = max(0, ts - lastTs)
        let dBytes = max(0, bytes - lastBytes)
        if lastTs > 0 && dt > 0 {
            out.bitrateBps = Int64(dBytes * 8 / dt)
        }
        let dFrames = max(0, framesDecoded - lastFramesDecoded)
        let dTime = max(0, decodeTime - lastDecodeTime)
        if dFrames > 0 {
            out.decodeMs = id(dTime / dFrames * 1000)
        }
        let dEmitted = max(0, jbEmitted - lastJbEmitted)
        let dJb = max(0, jbDelay - lastJbDelay)
        if dEmitted > 0 {
            out.jitterBufferMs = id(dJb / dEmitted * 1000)
        }
        let dLost = max(0, lost - lastPacketsLost)
        let dRecv = max(0, recv - lastPacketsReceived)
        if dLost + dRecv > 0 {
            out.packetLossPct = Float(dLost * 100 / (dLost + dRecv))
        }

        lastTs = ts; lastBytes = bytes; lastFramesDecoded = framesDecoded
        lastDecodeTime = decodeTime; lastJbDelay = jbDelay; lastJbEmitted = jbEmitted
        lastPacketsLost = lost; lastPacketsReceived = recv

        if let codecId = str(m["codecId"]), let c = report[codecId],
           let mime = str(c["mimeType"]) {
            out.codec = mime.split(separator: "/").last.map(String.init) ?? ""
        }
        out.decoder = str(m["decoderImplementation"]) ?? ""
        return out
    }

    // MARK: - 入口（每 2 秒调用一次）

    mutating func compute(_ report: Report) -> StreamStats {
        var out = StreamStats()
        let pair = Self.extractPair(report)
        out.rttMs = Self.id(pair.rtt * 1000)
        out.candidateType = pair.cand
        out.protocolName = pair.proto
        if let v = Self.extractVideo(report) {
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
