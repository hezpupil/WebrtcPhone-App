import Foundation
import WebRTC

/// 把累积型 getStats 报告转换成瞬时值（需要上一次采样做差分）。
/// 对齐 Android 端 StreamStats.kt / StatsCalculator.compute()。
///
/// 注意：本文件曾被 SIGTRAP 反复击穿（getStats 的 jitter/fps 等字段偶发 NaN/Infinity，
/// Swift Int(Double) 转换遇非有限值直接 trap）。因此：
/// 1. 所有 Double→Int/Int64 转换必须走 safeInt/safeInt64（isFinite 防御）；
/// 2. compute 拆分为独立小函数，崩溃栈的符号可精确指向子函数（配合 Release dSYM）。
final class StatsCalculator {
    private var lastTs = 0.0
    private var lastBytes: Int64 = 0
    private var lastFramesDecoded: Int64 = 0
    private var lastDecodeTime = 0.0
    private var lastJbDelay = 0.0
    private var lastJbEmitted: Int64 = 0
    private var lastPacketsLost: Int64 = 0
    private var lastPacketsRecv: Int64 = 0

    // MARK: - 安全转换（唯一允许的 Double→整数入口）

    private func safeInt(_ v: Double) -> Int { v.isFinite && v >= -9.2e18 && v <= 9.2e18 ? Int(v) : 0 }
    private func safeInt64(_ v: Double) -> Int64 { v.isFinite && v >= -9.2e18 && v <= 9.2e18 ? Int64(v) : 0 }
    private func safeDouble(_ v: Double) -> Double { v.isFinite ? v : 0 }
    private func num(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return safeDouble(n.doubleValue) }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }
    private func integer(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) ?? 0 }
        return 0
    }
    private func str(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        return nil
    }
    private func bool(_ v: Any?) -> Bool {
        if let b = v as? NSNumber { return b.boolValue }
        return false
    }
    /// Int64→Int（等宽不溢出，但保险起见 clamp）
    private func clampInt(_ v: Int64) -> Int { v > Int64(Int.max) ? Int.max : (v < Int64(Int.min) ? Int.min : Int(v)) }
    /// Int64 乘 8 防溢出（getStats 数值远达不到该量级，溢出回退 0）
    private func mul8(_ v: Int64) -> Int64 { v.magnitude < 1_152_921_504_606_846_976 ? v * 8 : 0 }

    // MARK: - 子函数（独立符号，崩溃栈可直接定位）

    /// 阶段 1：取报告字典
    private func statMap(_ report: RTCStatisticsReport) -> [String: RTCStatistics] {
        let d = report.statistics
        // statistics 在 ObjC 是 NSDictionary<NSString *, RTCStatistics *>，桥接失败则空
        return (d as NSDictionary) as? [String: RTCStatistics] ?? [:]
    }

    /// 阶段 2：候选对（RTT / 候选类型 / 协议）
    private func extractPair(_ map: [String: RTCStatistics]) -> (rtt: Double, cand: String, proto: String) {
        let pair = map.values.first { s in
            guard s.type == "candidate-pair", str(s.values["state"]) == "succeeded" else { return false }
            return bool(s.values["nominated"]) || bool(s.values["selected"])
        } ?? map.values.first { s in
            s.type == "candidate-pair" && str(s.values["state"]) == "succeeded"
        }
        guard let pair else { return (0, "", "") }
        let rtt = num(pair.values["currentRoundTripTime"])
        var cand = ""
        var proto = ""
        if let localId = str(pair.values["localCandidateId"]), let local = map[localId] {
            cand = str(local.values["candidateType"]) ?? ""
            proto = str(local.values["protocol"]) ?? ""
        }
        if let remoteId = str(pair.values["remoteCandidateId"]),
           let remote = map[remoteId], str(remote.values["candidateType"]) == "relay" {
            cand = "relay"
        }
        return (rtt, cand, proto)
    }

    /// 阶段 3：视频入站流差分
    private func extractVideo(_ map: [String: RTCStatistics]) -> StreamStats? {
        let video = map.values.first { s in
            s.type == "inbound-rtp" && (str(s.values["kind"]) == "video" || str(s.values["mediaType"]) == "video")
        }
        guard let video else { return nil }
        let m = video.values
        let ts = safeDouble(num(video.timestamp_us) / 1_000_000.0)
        let bytes = integer(m["bytesReceived"])
        let framesDecoded = integer(m["framesDecoded"])
        let decodeTime = num(m["totalDecodeTime"])
        let jbDelay = num(m["jitterBufferDelay"])
        let jbEmitted = integer(m["jitterBufferEmittedCount"])
        let lost = integer(m["packetsLost"])
        let recv = integer(m["packetsReceived"])
        let dt = ts - lastTs
        let dtSafe = dt > 0 ? dt : 0
        let delta = bytes >= lastBytes ? bytes - lastBytes : 0
        let bitrate = (lastTs > 0 && dtSafe > 0) ? mul8(delta) / safeInt64(dtSafe) : 0
        let dFrames = max(0, framesDecoded - lastFramesDecoded)
        let dTime = max(0, decodeTime - lastDecodeTime)
        let decodeMs = dFrames > 0 ? safeInt(dTime / Double(dFrames) * 1000) : 0
        let dEmitted = max(0, jbEmitted - lastJbEmitted)
        let dJb = max(0, jbDelay - lastJbDelay)
        let jbMs = dEmitted > 0 ? safeInt(dJb / Double(dEmitted) * 1000) : 0
        let dLost = max(0, lost - lastPacketsLost)
        let dRecv = max(0, recv - lastPacketsRecv)
        let loss = (dLost + dRecv) > 0 ? Float(dLost) * 100 / Float(dLost + dRecv) : 0
        var codec = ""
        if let codecId = str(m["codecId"]), let c = map[codecId], let mime = str(c.values["mimeType"]) {
            codec = mime.split(separator: "/").last.map(String.init) ?? ""
        }
        lastTs = ts; lastBytes = bytes; lastFramesDecoded = framesDecoded
        lastDecodeTime = decodeTime; lastJbDelay = jbDelay; lastJbEmitted = jbEmitted
        lastPacketsLost = lost; lastPacketsRecv = recv
        return StreamStats(
            rttMs: 0, fps: safeInt(num(m["framesPerSecond"])),
            bitrateBps: max(0, bitrate), width: clampInt(integer(m["frameWidth"])),
            height: clampInt(integer(m["frameHeight"])), packetLossPct: max(0, loss),
            jitterMs: safeInt(num(m["jitter"]) * 1000), decodeMs: decodeMs,
            jitterBufferMs: jbMs, framesDropped: integer(m["framesDropped"]),
            codec: codec, decoder: str(m["decoderImplementation"]) ?? "",
            candidateType: "", protocolName: ""
        )
    }

    // MARK: - 入口

    func compute(_ report: RTCStatisticsReport) -> StreamStats {
        var out = StreamStats()
        let map = statMap(report)
        let pairInfo = extractPair(map)
        out.rttMs = safeInt(pairInfo.rtt * 1000)
        out.candidateType = pairInfo.cand
        out.protocolName = pairInfo.proto
        if let v = extractVideo(map) {
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
