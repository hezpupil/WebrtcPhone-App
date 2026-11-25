import Foundation
import WebRTC

/// 把累积型 getStats 报告转换成瞬时值（需要上一次采样做差分）。
/// 对齐 Android 端 StreamStats.kt / StatsCalculator.compute()。
final class StatsCalculator {
    private var lastTs = 0.0
    private var lastBytes: Int64 = 0
    private var lastFramesDecoded: Int64 = 0
    private var lastDecodeTime = 0.0
    private var lastJbDelay = 0.0
    private var lastJbEmitted: Int64 = 0
    private var lastPacketsLost: Int64 = 0
    private var lastPacketsRecv: Int64 = 0

    func compute(_ report: RTCStatisticsReport) -> StreamStats {
        let map = report.statistics as? [String: RTCStatistics] ?? [:]
        var rtt = 0.0
        var candidateType = ""
        var proto = ""
        var codec = ""
        var out = StreamStats()

        // 候选对：优先 nominated/selected 且 succeeded
        let pair = map.values.first { s in
            guard s.type == "candidate-pair", str(s.values["state"]) == "succeeded" else { return false }
            return bool(s.values["nominated"]) || bool(s.values["selected"])
        } ?? map.values.first { s in
            s.type == "candidate-pair" && str(s.values["state"]) == "succeeded"
        }
        if let pair {
            rtt = num(pair.values["currentRoundTripTime"])
            if let localId = str(pair.values["localCandidateId"]),
               let local = map[localId] {
                candidateType = str(local.values["candidateType"]) ?? ""
                proto = str(local.values["protocol"]) ?? ""
            }
            if let remoteId = str(pair.values["remoteCandidateId"]),
               let remote = map[remoteId], str(remote.values["candidateType"]) == "relay" {
                candidateType = "relay"
            }
        }

        // 视频入站流
        if let video = map.values.first(where: { s in
            s.type == "inbound-rtp" && (str(s.values["kind"]) == "video" || str(s.values["mediaType"]) == "video")
        }) {
            let m = video.values
            let ts = video.timestamp_us / 1_000_000.0
            let bytes = integer(m["bytesReceived"])
            let framesDecoded = integer(m["framesDecoded"])
            let decodeTime = num(m["totalDecodeTime"])
            let jbDelay = num(m["jitterBufferDelay"])
            let jbEmitted = integer(m["jitterBufferEmittedCount"])
            let lost = integer(m["packetsLost"])
            let recv = integer(m["packetsReceived"])
            let dt = ts - lastTs
            let dtSafe = dt.isFinite && dt > 0 ? dt : 0
            let bitrate = (lastTs > 0 && dtSafe > 0) ? (bytes - lastBytes) * 8 / safeInt64(dtSafe) : 0
            let dFrames = framesDecoded - lastFramesDecoded
            let decodeMs = dFrames > 0 ? safeInt((decodeTime - lastDecodeTime) / Double(dFrames) * 1000) : 0
            let dEmitted = jbEmitted - lastJbEmitted
            let jbMs = dEmitted > 0 ? safeInt((jbDelay - lastJbDelay) / Double(dEmitted) * 1000) : 0
            let dLost = lost - lastPacketsLost
            let dRecv = recv - lastPacketsRecv
            let loss = (dLost + dRecv) > 0 ? Float(dLost) * 100 / Float(dLost + dRecv) : 0
            if let codecId = str(m["codecId"]), let c = map[codecId], let mime = str(c.values["mimeType"]) {
                codec = mime.split(separator: "/").last.map(String.init) ?? ""
            }
            out = StreamStats(
                rttMs: safeInt(rtt * 1000), fps: safeInt(num(m["framesPerSecond"])),
                bitrateBps: max(0, bitrate), width: safeInt(Double(integer(m["frameWidth"]))),
                height: safeInt(Double(integer(m["frameHeight"]))), packetLossPct: max(0, loss),
                jitterMs: safeInt(num(m["jitter"]) * 1000), decodeMs: max(0, decodeMs),
                jitterBufferMs: max(0, jbMs), framesDropped: integer(m["framesDropped"]),
                codec: codec, decoder: str(m["decoderImplementation"]) ?? "",
                candidateType: candidateType, protocolName: proto
            )
            lastTs = ts; lastBytes = bytes; lastFramesDecoded = framesDecoded
            lastDecodeTime = decodeTime; lastJbDelay = jbDelay; lastJbEmitted = jbEmitted
            lastPacketsLost = lost; lastPacketsRecv = recv
        }
        out.rttMs = safeInt(rtt * 1000)
        out.candidateType = candidateType
        out.protocolName = proto
        if !codec.isEmpty { out.codec = codec }
        return out
    }

    private func num(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) ?? 0 }
        return 0
    }
    /// getStats 的 jitter/framesPerSecond 等字段可能返回 NaN/Infinity，
    /// Swift 的 Int(Double) 遇到非有限值会直接 trap（SIGTRAP），必须防御
    private func safeInt(_ v: Double) -> Int { v.isFinite ? Int(v) : 0 }
    private func safeInt64(_ v: Double) -> Int64 { v.isFinite ? Int64(v) : 0 }
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
        if let b = v as? Bool { return b }
        return false
    }
}
