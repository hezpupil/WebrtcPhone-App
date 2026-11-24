import Foundation

/// 生成 request-offer 的 scrcpy_options。对齐 Android 端 ScrcpyOptions.kt。
/// 关键：video_source 两种模式必须显式发送（agent 跨会话保留上次取值）。
enum ScrcpyOptions {
    static func build(_ target: StreamTarget) -> [String: Any] {
        let s = target.settings
        let mbps = 1_000_000
        var o: [String: Any] = [
            "max_fps": s.maxFps,
            "max_size": s.maxSize,
            "bitrate": s.bitrateMbps * mbps,
            "min_bitrate": s.minBitrateMbps * mbps,
            "max_bitrate": s.maxBitrateMbps * mbps,
            "bwe": s.bwe,
            "audio": s.audio,
            "audio_gain": 1,
            "audio_source": "output",
            "audio_dup": true,
            "audio_low_latency": false,
            "power_off": s.powerOff,
        ]

        switch target.mode {
        case .screen:
            o["video_source"] = "display"
        case .camera(let c):
            o["video_source"] = "camera"
            o["camera_facing"] = c.facing
            o["camera_id"] = c.cameraId
            o["camera_size"] = c.size
            o["camera_fps"] = c.fps
            o["camera_high_speed"] = false
            o["camera_ar"] = "16:9"
            o["camera_zoom"] = c.zoom
            o["camera_orientation"] = "auto"
            o["camera_low_power"] = false
            if c.micAudio {
                o["audio"] = true
                o["audio_source"] = "mic"
            }
        }
        return o
    }
}
