import Foundation

/// WS 备用投屏协议。对齐 Android 端 WsProtocol.kt。
enum WsProtocol {
    static let prevHeaderLen = 49
    static let deviceIdLen = 32

    struct PrevFrame: Equatable {
        let deviceId: String
        let isKey: Bool
        let ptsUs: UInt64
        let nalu: Data
    }

    /// PREV 帧 49 字节头（全部大端）
    /// [0..4) magic "PREV" | [4..36) device_id UTF-8 \0 填充 | [36] key flag
    /// [37..45) ptsUs uint64 BE | [45..49) payloadLen uint32 BE | [49..) NALU
    static func parsePrev(_ data: Data) -> PrevFrame? {
        let bytes = [UInt8](data)
        guard bytes.count >= prevHeaderLen, bytes[0] == 0x50, bytes[1] == 0x52,
              bytes[2] == 0x45, bytes[3] == 0x56 else { return nil }

        var idBytes: [UInt8] = []
        for i in 4..<(4 + deviceIdLen) {
            if bytes[i] == 0 { break }
            idBytes.append(bytes[i])
        }
        let deviceId = String(bytes: idBytes, encoding: .utf8) ?? ""
        let isKey = bytes[36] == 1
        var pts: UInt64 = 0
        for i in 37..<45 { pts = (pts << 8) | UInt64(bytes[i]) }
        var len: UInt32 = 0
        for i in 45..<49 { len = (len << 8) | UInt32(bytes[i]) }
        let payloadLen = Int(len)
        guard payloadLen >= 0, bytes.count >= prevHeaderLen + payloadLen else { return nil }

        let nalu = Data(bytes[prevHeaderLen..<(prevHeaderLen + payloadLen)])
        return PrevFrame(deviceId: deviceId, isKey: isKey, ptsUs: pts, nalu: nalu)
    }

    static func startPreview(deviceId: String, fps: Int, maxSize: Int,
                             bitrateBps: Int, stayAwake: Bool) -> String {
        var o: [String: Any] = [
            "message_type": "start_preview",
            "type": "start_preview",
            "device_id": deviceId,
            "stay_awake": stayAwake,
        ]
        if fps > 0 { o["fps"] = fps }
        if maxSize > 0 { o["max_size"] = maxSize }
        if bitrateBps > 0 { o["bitrate"] = bitrateBps }
        return json(o)
    }

    static func stopPreview(_ deviceId: String) -> String {
        json(["message_type": "stop_preview", "type": "stop_preview", "device_id": deviceId])
    }

    /// 顶层只有 message_type，无 type；event 为 InputProtocol 事件对象
    static func groupControlEvent(_ deviceId: String, event: [String: Any]) -> String {
        json(["message_type": "group_control_event",
              "target_device_ids": [deviceId],
              "event": event])
    }

    private static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
