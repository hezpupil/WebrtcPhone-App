import Foundation

/// 容错 JSON 解析器。对齐 Android 端 data/model/Parsers.kt。
/// 所有函数对缺失字段使用默认值，不抛异常。
enum Parsers {
    /// 对齐 Android JSONObject.optString：数字 / NSNull 都能安全转字符串
    private static func str(_ o: [String: Any], _ key: String, _ def: String = "") -> String {
        guard let v = o[key], !(v is NSNull) else { return def }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return def
    }
    /// 对齐 Android JSONObject.optBoolean：bool / 数字(1/0) / 字符串(true/false) 均可
    private static func bool(_ o: [String: Any], _ key: String, _ def: Bool = false) -> Bool {
        guard let v = o[key], !(v is NSNull) else { return def }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String {
            switch s.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return def
            }
        }
        return def
    }
    private static func int(_ o: [String: Any], _ key: String, _ def: Int = 0) -> Int {
        if let n = o[key] as? NSNumber { return n.intValue }
        if let s = o[key] as? String, let v = Int(s) { return v }
        return def
    }
    private static func int64(_ o: [String: Any], _ key: String, _ def: Int64 = 0) -> Int64 {
        if let n = o[key] as? NSNumber { return n.int64Value }
        if let s = o[key] as? String, let v = Int64(s) { return v }
        return def
    }
    private static func double(_ o: [String: Any], _ key: String, _ def: Double = 0) -> Double {
        if let n = o[key] as? NSNumber { return n.doubleValue }
        if let s = o[key] as? String, let v = Double(s) { return v }
        return def
    }
    private static func optDate(_ o: [String: Any], _ key: String) -> Date? {
        guard let s = o[key] as? String else { return nil }
        return Rfc3339.parse(s)
    }
    private static func strings(_ any: Any?) -> [String] {
        (any as? [Any])?.compactMap { $0 as? String } ?? []
    }
    private static func objects(_ any: Any?) -> [[String: Any]] {
        (any as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    // MARK: 登录与 Me

    static func loginResult(_ data: Data) throws -> (token: String, username: String, role: String) {
        let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let token = o["token"] as? String, !token.isEmpty else {
            throw ApiError.parse("服务器响应缺少 token")
        }
        return (token, str(o, "username"), str(o, "role", "user"))
    }

    static func policy(_ o: [String: Any]) -> UserPolicy {
        var p = UserPolicy()
        p.forbidBitrate = bool(o, "forbid_bitrate")
        p.forbidFps = bool(o, "forbid_fps")
        p.forbidResolution = bool(o, "forbid_resolution")
        p.forbidAudio = bool(o, "forbid_audio")
        p.forbidFilePush = bool(o, "forbid_file_push")
        p.forbidTerminal = bool(o, "forbid_terminal")
        p.forbidShare = bool(o, "forbid_share")
        return p
    }

    static func me(_ data: Data) throws -> Me {
        let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let leases = objects(o["leases"]).map { l in
            Lease(deviceId: str(l, "device_id"),
                  expiresAt: optDate(l, "expires_at"),
                  remainingSeconds: int64(l, "remaining_seconds", -1))
        }
        return Me(username: str(o, "username"),
                  role: str(o, "role", "user"),
                  expiresAt: optDate(o, "expires_at"),
                  policy: policy(o),
                  leases: leases)
    }

    // MARK: 设备

    static func deviceInfo(_ o: [String: Any]?) -> DeviceInfo {
        guard let o else { return DeviceInfo() }
        var info = DeviceInfo()
        info.model = str(o, "model")
        info.brand = str(o, "brand")
        info.androidVersion = str(o, "android_version")
        info.sdkInt = (o["sdk_int"] as? NSNumber)?.stringValue ?? str(o, "sdk_int")
        info.cpuAbi = str(o, "cpu_abi")
        info.memTotalMb = int64(o, "mem_total_mb")
        info.isEmulator = bool(o, "is_emulator")
        info.agentVersion = str(o, "agent_version", str(o, "app_version"))
        info.cameraSupport = bool(o, "camera_support")
        info.projectionOnDemand = bool(o, "projection_on_demand")
        info.cameras = objects(o["cameras"]).map { c in
            let z = double(c, "zoom", 1.0)
            return CameraLens(id: str(c, "id", "0"),
                              facing: str(c, "facing", "back"),
                              type: str(c, "type"), name: str(c, "name"),
                              zoom: z.isFinite ? z : 1.0)
        }
        info.displays = objects(o["displays"]).compactMap { d in
            let w = int(d, "x_res"), h = int(d, "y_res")
            return w > 0 && h > 0 ? DisplayInfo(width: w, height: h) : nil
        }
        return info
    }

    static func device(_ o: [String: Any]) -> Device {
        let clients = objects(o["clients"]).map { c in
            DeviceClient(name: str(c, "name"), kind: str(c, "kind", "user"),
                         remainingSeconds: int64(c, "remaining_seconds", -1),
                         count: int(c, "count", 1))
        }
        var myLease: Int64? = nil
        if let n = o["my_lease_remaining_seconds"] as? NSNumber { myLease = n.int64Value }
        let holder = (o["lease"] as? [String: Any]).flatMap { str($0, "username") }.flatMap { $0.isEmpty ? nil : $0 }
        return Device(
            id: str(o, "device_id", str(o, "id")),
            info: deviceInfo(o["device_info"] as? [String: Any]),
            online: bool(o, "online"),
            screenState: str(o, "screen_state"),
            lastSeen: optDate(o, "last_seen"),
            clientCount: int(o, "client_count"),
            clients: clients,
            myLeaseRemainingSeconds: myLease,
            leaseHolder: holder,
            alias: str(o, "display_name", str(o, "alias"))
        )
    }

    /// 接受 JSON 数组或 {"devices":[...]} 两种形态
    static func devices(_ data: Data) throws -> [Device] {
        let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty || t == "null" { return [] }
        let any = try JSONSerialization.jsonObject(with: data)
        let arr: [Any]
        if let a = any as? [Any] { arr = a }
        else if let o = any as? [String: Any], let a = o["devices"] as? [Any] { arr = a }
        else { return [] }
        return arr.compactMap { $0 as? [String: Any] }.map(device).filter { !$0.id.isEmpty }
    }

    // MARK: 标签

    static func tags(_ o: [String: Any]) -> TagsPayload {
        let list = objects(o["tags"]).map { t in
            Tag(id: str(t, "id"), name: str(t, "name"), color: str(t, "color", "#3B82F6"))
        }
        var map: [String: [String]] = [:]
        if let dt = o["deviceTags"] as? [String: Any] {
            for (k, v) in dt { map[k] = strings(v) }
        }
        return TagsPayload(tags: list, deviceTags: map)
    }

    static func tagsToJson(_ payload: TagsPayload) -> [String: Any] {
        let list = payload.tags.map { ["id": $0.id, "name": $0.name, "color": $0.color] as [String: Any] }
        var map: [String: Any] = [:]
        for (k, ids) in payload.deviceTags where !ids.isEmpty { map[k] = ids }
        return ["tags": list, "deviceTags": map]
    }

    // MARK: 分享

    static func share(_ o: [String: Any]) -> Share {
        Share(token: str(o, "token_id", str(o, "token")),
              cardCode: str(o, "card_code"),
              deviceId: str(o, "device_id"),
              creator: str(o, "creator"),
              createdAt: optDate(o, "created_at"),
              expiresAt: optDate(o, "expires_at"),
              accessMode: AccessMode.of(str(o, "access_mode")),
              requirePassword: bool(o, "require_password"),
              allowClipboard: bool(o, "allow_clipboard"),
              allowFileTx: bool(o, "allow_file_tx"),
              description: str(o, "description"),
              useCount: int64(o, "use_count"),
              lastUsedAt: optDate(o, "last_used_at"),
              activeConnections: int(o, "active_connections"))
    }

    static func shares(_ data: Data) throws -> [Share] {
        let any = try JSONSerialization.jsonObject(with: data)
        return objects(any).map(share).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    static func shareCreated(_ o: [String: Any]) -> ShareCreated {
        ShareCreated(token: str(o, "token"), cardCode: str(o, "card_code"),
                     shareUrl: str(o, "share_url"), expiresAt: optDate(o, "expires_at"))
    }

    // MARK: 管理

    static func adminUsers(_ data: Data) throws -> [AdminUser] {
        let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty || t == "null" { return [] }
        let any = try JSONSerialization.jsonObject(with: data)
        return objects(any).map { o in
            AdminUser(username: str(o, "username"), role: str(o, "role", "user"),
                      note: str(o, "note"), online: bool(o, "online"),
                      activeDevices: strings(o["active_devices"]),
                      expiresAt: optDate(o, "expires_at"),
                      policy: policy(o))
        }
    }

    static func adminLease(_ o: [String: Any]) -> AdminLease {
        AdminLease(leaseId: str(o, "lease_id", str(o, "id")),
                   username: str(o, "username"), deviceId: str(o, "device_id"),
                   createdAt: optDate(o, "created_at"), expiresAt: optDate(o, "expires_at"),
                   remainingSeconds: int64(o, "remaining_seconds", -1),
                   active: bool(o, "active"), note: str(o, "note"),
                   createdBy: str(o, "created_by"), revokedAt: optDate(o, "revoked_at"),
                   policyOverride: (o["policy_override"] as? [String: Any]).map(policy))
    }

    static func adminLeases(_ data: Data) throws -> [AdminLease] {
        let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty || t == "null" { return [] }
        let any = try JSONSerialization.jsonObject(with: data)
        return objects(any).map(adminLease)
    }

    // MARK: 快捷文本 / 文件 / 任务

    static func quickTexts(_ data: Data) throws -> [QuickText] {
        let any = try JSONSerialization.jsonObject(with: data)
        return objects(any).map { o in
            QuickText(id: str(o, "id"), title: str(o, "title"), content: str(o, "content"),
                      autoEnter: bool(o, "auto_enter"), createdAt: int64(o, "created_at"))
        }
    }

    static func quickTextsToJson(_ list: [QuickText]) -> [[String: Any]] {
        list.map { ["id": $0.id, "title": $0.title, "content": $0.content,
                    "auto_enter": $0.autoEnter, "created_at": $0.createdAt] }
    }

    static func serverFiles(_ data: Data) throws -> [ServerFile] {
        let t = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty || t == "null" { return [] }
        let any = try JSONSerialization.jsonObject(with: data)
        return objects(any).compactMap { o in
            let name = str(o, "name")
            if name.isEmpty { return nil }
            return ServerFile(name: name, size: int64(o, "size"),
                              updatedAt: optDate(o, "updated_at") ?? .distantPast,
                              url: str(o, "url"), owner: str(o, "owner"))
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    static func taskDetails(_ o: [String: Any]) -> TaskDetails {
        var devices: [String: SubTaskStatus] = [:]
        if let map = o["devices"] as? [String: Any] {
            for (k, raw) in map {
                guard let d = raw as? [String: Any] else { continue }
                devices[k] = SubTaskStatus(deviceId: str(d, "device_id", k),
                                           status: str(d, "status"),
                                           progress: int(d, "progress"),
                                           result: str(d, "result"))
            }
        }
        return TaskDetails(taskId: str(o, "task_id"), type: str(o, "type"), devices: devices)
    }
}
