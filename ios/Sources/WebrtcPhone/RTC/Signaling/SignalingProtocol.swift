import Foundation

struct IceServerSpec: Equatable {
    var urls: [String] = []
    var username: String?
    var credential: String?
}

struct CandidateSpec: Equatable {
    var sdpMid: String?
    var sdpMLineIndex: Int
    var candidate: String
}

/// 入站信令消息。对齐 Android 端 SignalingMessage。
enum SignalingMessage: Equatable {
    case config([IceServerSpec])
    case deviceInfo([String: Any])
    case projectionStatus(String)
    case offer(String)
    case answer(String)
    case candidate(CandidateSpec)
    case error(code: String, message: String)
    case pong
    case other(String)

    // Equatable for associated dictionaries via description (仅用于测试比较)
    static func == (lhs: SignalingMessage, rhs: SignalingMessage) -> Bool {
        switch (lhs, rhs) {
        case (.config(let a), .config(let b)): return a == b
        case (.deviceInfo(let a), .deviceInfo(let b)): return (a as NSDictionary).isEqual(to: b)
        case (.projectionStatus(let a), .projectionStatus(let b)),
             (.offer(let a), .offer(let b)), (.answer(let a), .answer(let b)),
             (.other(let a), .other(let b)): return a == b
        case (.candidate(let a), .candidate(let b)): return a == b
        case (.error(let c1, let m1), .error(let c2, let m2)): return c1 == c2 && m1 == m2
        case (.pong, .pong): return true
        default: return false
        }
    }
}

/// 信令 JSON 构造与解析。逐字段对齐 Android 端 SignalingProtocol.kt。
enum SignalingProtocol {
    static let ping = "{\"type\":\"ping\"}"

    static func connect(_ deviceId: String) -> String {
        json(["message_type": "connect", "device_id": deviceId])
    }

    static func forward(_ deviceId: String, _ payload: [String: Any]) -> String {
        json(["message_type": "forward", "device_id": deviceId, "payload": payload])
    }

    static func requestOffer(_ deviceId: String, options: [String: Any], resumeKey: String?) -> String {
        var payload: [String: Any] = [
            "type": "request-offer",
            "ip_preference": "auto",
            "scrcpy_options": options,
        ]
        // null 不写入（对齐 org.json.put(key, null) 移除键）
        if let resumeKey { payload["projection_resume_key"] = resumeKey }
        return forward(deviceId, payload)
    }

    static func answer(_ deviceId: String, sdp: String) -> String {
        forward(deviceId, ["type": "answer", "sdp": sdp])
    }

    static func candidate(_ deviceId: String, c: CandidateSpec) -> String {
        var cand: [String: Any] = [
            "candidate": c.candidate,
            "sdpMLineIndex": c.sdpMLineIndex,
        ]
        if let mid = c.sdpMid { cand["sdpMid"] = mid; cand["mid"] = mid }
        return forward(deviceId, ["type": "ice-candidate", "candidate": cand])
    }

    static func projectionEnd(_ deviceId: String, resumeKey: String?) -> String {
        var payload: [String: Any] = ["type": "projection-end"]
        if let resumeKey { payload["projection_resume_key"] = resumeKey }
        return forward(deviceId, payload)
    }

    /// type 取 message_type，为空回退 type
    static func parse(_ text: String) -> SignalingMessage? {
        guard let data = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var type = o["message_type"] as? String ?? ""
        if type.isEmpty { type = o["type"] as? String ?? "" }
        switch type {
        case "pong": return .pong
        case "config": return .config(parseIceServers(o["ice_servers"]))
        case "device_info": return .deviceInfo(o["device_info"] as? [String: Any] ?? [:])
        case "device_msg":
            guard let payload = o["payload"] as? [String: Any] else { return nil }
            return parsePayload(payload)
        case "error":
            let message = (o["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (o["msg"] as? String ?? "服务器错误")
            return .error(code: o["code"] as? String ?? "", message: message)
        case "offer", "answer", "ice-candidate":
            return parsePayload(o)
        default:
            return .other(type)
        }
    }

    private static func parsePayload(_ p: [String: Any]) -> SignalingMessage? {
        let type = p["type"] as? String ?? ""
        switch type {
        case "projection_status":
            return .projectionStatus(p["state"] as? String ?? "")
        case "offer":
            let sdp = p["sdp"] as? String ?? ""
            return sdp.isEmpty ? nil : .offer(sdp)
        case "answer":
            let sdp = p["sdp"] as? String ?? ""
            return sdp.isEmpty ? nil : .answer(sdp)
        case "ice-candidate":
            let c = (p["candidate"] as? [String: Any]) ?? p
            let sdp = c["candidate"] as? String ?? ""
            if sdp.isEmpty { return nil }
            let mid = (c["sdpMid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (c["mid"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .candidate(CandidateSpec(sdpMid: mid,
                                            sdpMLineIndex: c["sdpMLineIndex"] as? Int ?? 0,
                                            candidate: sdp))
        default:
            return nil
        }
    }

    private static func parseIceServers(_ any: Any?) -> [IceServerSpec] {
        guard let arr = any as? [Any] else { return [] }
        return arr.compactMap { item -> IceServerSpec? in
            guard let o = item as? [String: Any] else { return nil }
            let rawUrls = o["urls"] ?? o["url"]
            let urls: [String]
            if let list = rawUrls as? [Any] {
                urls = list.compactMap { $0 as? String }.filter { !$0.isEmpty }
            } else if let s = rawUrls as? String {
                urls = [s]
            } else { urls = [] }
            if urls.isEmpty { return nil }
            return IceServerSpec(urls: urls,
                                 username: (o["username"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                 credential: (o["credential"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    private static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
