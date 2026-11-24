import Foundation

// MARK: - 鉴权

enum StreamAuth: Equatable {
    case user(token: String)
    case share(shareToken: String, password: String)
}

// MARK: - 投屏模式

struct CameraParams: Equatable {
    var facing = "back"
    var cameraId = "0"
    var size = "1920x1080"
    var fps = 30
    var zoom = 1.0
    var micAudio = true
}

enum StreamMode: Equatable {
    case screen
    case camera(CameraParams)
}

enum StreamTransport: String, Equatable {
    case webrtc
    case websocket
}

// MARK: - 连接阶段

enum ConnectionPhase: Equatable {
    case signaling
    case waitingOffer
    case waitingProjection
    case negotiating
    case connected
    /// ICE 瞬断宽限
    case interrupted
    case failed(message: String, retryable: Bool, authError: Bool = false)
    case closed

    var isTerminal: Bool {
        if case .failed = self { return true }
        if case .closed = self { return true }
        return false
    }
}

// MARK: - 统计

struct StreamStats: Equatable {
    var rttMs = 0
    var fps = 0
    var bitrateBps: Int64 = 0
    var width = 0
    var height = 0
    var packetLossPct: Float = 0
    var jitterMs = 0
    var decodeMs = 0
    var jitterBufferMs = 0
    var framesDropped: Int64 = 0
    var codec = ""
    var decoder = ""
    /// host / srflx / prflx / relay
    var candidateType = ""
    var protocolName = ""

    var latencyMs: Int {
        if rttMs == 0 && jitterBufferMs == 0 { return 0 }
        return rttMs / 2 + jitterBufferMs + decodeMs + 8
    }
    var networkLabel: String {
        switch candidateType {
        case "host": return "局域网直连"
        case "srflx", "prflx": return "P2P 穿透"
        case "relay": return "TURN 中继"
        default: return ""
        }
    }
}

// MARK: - StreamTarget

/// 一次投屏的全部不可变输入。修改画质 / 切镜头 / 切设备 = 以新 target 重建会话。
struct StreamTarget: Equatable {
    let endpoint: ServerEndpoint
    let deviceId: String
    let deviceName: String
    let auth: StreamAuth
    var accessMode: AccessMode = .full
    var allowClipboard = true
    var allowFileTx = true
    var allowTerminal = true
    var mode: StreamMode = .screen
    var settings: StreamSettings = StreamSettings()
    var transport: StreamTransport = .webrtc
    var displayHint: (Int, Int)?
    var projectionOnDemand = false

    /// 仅必填字段的便捷构造（其余走默认值）
    init(endpoint: ServerEndpoint, deviceId: String, deviceName: String, auth: StreamAuth) {
        self.endpoint = endpoint
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.auth = auth
    }

    var viewOnly: Bool { accessMode == AccessMode.viewOnly }
    var isGuest: Bool { if case .share = auth { return true }; return false }
    var isCamera: Bool { if case .camera = mode { return true }; return false }
    var isWs: Bool { transport == .websocket }
}
