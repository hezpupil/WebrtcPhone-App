import Foundation

// MARK: - 会话与权限

struct AuthSession: Codable, Equatable {
    let server: String
    let token: String
    let username: String
    let role: String
    var isAdmin: Bool { role == "admin" }
}

struct UserPolicy: Codable, Equatable {
    var forbidBitrate = false
    var forbidFps = false
    var forbidResolution = false
    var forbidAudio = false
    var forbidFilePush = false
    var forbidTerminal = false
    var forbidShare = false
}

struct Lease: Codable, Equatable {
    let deviceId: String
    let expiresAt: Date?
    let remainingSeconds: Int64
}

struct Me: Codable, Equatable {
    let username: String
    let role: String
    let expiresAt: Date?
    let policy: UserPolicy
    let leases: [Lease]
}

// MARK: - 设备

struct DisplayInfo: Codable, Equatable {
    let width: Int
    let height: Int
}

struct CameraLens: Codable, Equatable {
    let id: String
    let facing: String
    let type: String
    let name: String
    let zoom: Double
}

struct DeviceInfo: Codable, Equatable {
    var model = ""
    var brand = ""
    var androidVersion = ""
    var sdkInt = ""
    var cpuAbi = ""
    var memTotalMb: Int64 = 0
    var isEmulator = false
    var agentVersion = ""
    var cameraSupport = false
    var cameras: [CameraLens] = []
    var displays: [DisplayInfo] = []
    var projectionOnDemand = false

    var primaryDisplay: DisplayInfo? { displays.first }
    var title: String { [brand, model].filter { !$0.isEmpty }.joined(separator: " ") }
}

struct DeviceClient: Codable, Equatable {
    let name: String
    let kind: String
    let remainingSeconds: Int64
    let count: Int
}

struct Device: Codable, Equatable, Identifiable {
    let id: String
    var info = DeviceInfo()
    var online = false
    var screenState = ""
    var lastSeen: Date?
    var clientCount = 0
    var clients: [DeviceClient] = []
    var myLeaseRemainingSeconds: Int64?
    var leaseHolder: String?
    var alias = ""

    var displayName: String { alias.isEmpty ? id : alias }
    var inUse: Bool { clientCount > 0 }
    var screenOff: Bool { screenState.lowercased() == "off" }
}

// MARK: - 标签

struct Tag: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let color: String
}

struct TagsPayload: Equatable {
    var tags: [Tag] = []
    var deviceTags: [String: [String]] = [:]
    static let empty = TagsPayload()
}

// MARK: - 快捷文本

struct QuickText: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let content: String
    let autoEnter: Bool
    let createdAt: Int64
}

// MARK: - 分享

enum AccessMode: String, Codable, Equatable {
    case full = "full"
    case viewOnly = "view_only"

    var label: String { self == .full ? "完全控制" : "仅观看" }
    static func of(_ wire: String?) -> AccessMode {
        AccessMode(rawValue: wire ?? "") ?? .full
    }
}

struct Share: Codable, Equatable, Identifiable {
    let token: String
    let cardCode: String
    let deviceId: String
    let creator: String
    let createdAt: Date?
    let expiresAt: Date?
    let accessMode: AccessMode
    let requirePassword: Bool
    let allowClipboard: Bool
    let allowFileTx: Bool
    let description: String
    let useCount: Int64
    let lastUsedAt: Date?
    let activeConnections: Int

    var id: String { token }
}

struct ShareCreateRequest: Equatable {
    let deviceId: String
    let expireSeconds: Int64
    let accessMode: AccessMode
    let password: String
    let description: String
    let allowClipboard: Bool
    let allowFileTx: Bool
    let customCardCode: String
}

struct ShareCreated: Codable, Equatable {
    let token: String
    let cardCode: String
    let shareUrl: String
    let expiresAt: Date?
}

// MARK: - 管理：用户与租约

struct AdminUser: Codable, Equatable, Identifiable {
    let username: String
    let role: String
    let note: String
    let online: Bool
    let activeDevices: [String]
    let expiresAt: Date?
    let policy: UserPolicy

    var id: String { username }
    var isAdmin: Bool { role == "admin" }
    func isExpired(now: Date = Date()) -> Bool {
        guard let exp = expiresAt else { return false }
        return exp < now
    }
}

struct AdminUserCreate: Equatable {
    let username: String
    let password: String
    let role: String
    let note: String
    let expireSeconds: Int64
}

struct AdminLease: Codable, Equatable, Identifiable {
    let leaseId: String
    let username: String
    let deviceId: String
    let createdAt: Date?
    let expiresAt: Date?
    /// -1 表示永久，>=0 剩余秒数
    let remainingSeconds: Int64
    let active: Bool
    let note: String
    let createdBy: String
    let revokedAt: Date?
    let policyOverride: UserPolicy?

    var id: String { leaseId }
    var isPermanent: Bool { remainingSeconds < 0 }
    var isRevoked: Bool { revokedAt != nil }
    func isExpiringSoon(threshold: Int64 = 86_400 * 3) -> Bool {
        remainingSeconds >= 0 && remainingSeconds < threshold
    }
}

struct LeaseCreateRequest: Equatable {
    let username: String
    let deviceId: String
    /// <=0 表示永久
    let durationSeconds: Int64
    let note: String
    let policyOverride: UserPolicy?
}

// MARK: - 服务器中转文件与任务

struct ServerFile: Codable, Equatable, Hashable, Identifiable {
    let name: String
    let size: Int64
    let updatedAt: Date
    let url: String
    let owner: String
    var id: String { name }
}

struct SubTaskStatus: Codable, Equatable {
    let deviceId: String
    /// queued / running / success / failed
    let status: String
    let progress: Int
    let result: String

    var finished: Bool {
        ["success", "failed", "done", "error", "completed"].contains(status.lowercased())
    }
    var ok: Bool {
        ["success", "done", "completed"].contains(status.lowercased())
    }
}

struct TaskDetails: Codable, Equatable {
    let taskId: String
    let type: String
    let devices: [String: SubTaskStatus]
}

enum ServerTaskType: String, Equatable {
    case install = "install"
    case pushFile = "push_file"
}

// MARK: - 纯函数工具（对齐 Android 端 TagOps / ServerFileOps）

enum TagOps {
    /// 新增或按 id 覆盖一个标签
    static func upsert(_ p: TagsPayload, _ tag: Tag) -> TagsPayload {
        var next = p
        if let i = next.tags.firstIndex(where: { $0.id == tag.id }) { next.tags[i] = tag }
        else { next.tags.append(tag) }
        return next
    }

    /// 删除标签定义，并从所有设备映射中移除；映射清空的设备条目一并删除
    static func delete(_ p: TagsPayload, _ tagId: String) -> TagsPayload {
        var next = p
        next.tags.removeAll { $0.id == tagId }
        next.deviceTags = next.deviceTags.mapValues { $0.filter { $0 != tagId } }
                                          .filter { !$0.value.isEmpty }
        return next
    }

    /// 设置某设备的标签集合；空集合等价于删除该设备映射
    static func setDeviceTags(_ p: TagsPayload, _ deviceId: String, _ tagIds: [String]) -> TagsPayload {
        var next = p
        if tagIds.isEmpty { next.deviceTags.removeValue(forKey: deviceId) }
        else { next.deviceTags[deviceId] = tagIds }
        return next
    }

    static func isDuplicateName(_ tags: [Tag], name: String, selfId: String?) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return false }
        return tags.contains { $0.id != selfId && $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(n) == .orderedSame }
    }

    static func newTagId() -> String {
        "tag_" + String(UUID().uuidString.prefix(8))
    }
}

enum ServerFileOps {
    static func taskTypeFor(_ fileName: String) -> ServerTaskType {
        (fileName as NSString).pathExtension.lowercased() == "apk" ? .install : .pushFile
    }

    static func defaultDestPath(_ fileName: String) -> String {
        let base = (fileName as NSString).lastPathComponent
        return "/sdcard/Download/" + base
    }

    static func absoluteUrl(httpBase: String, signedPath: String) -> String {
        if signedPath.hasPrefix("http://") || signedPath.hasPrefix("https://") { return signedPath }
        return httpBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/" + signedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
