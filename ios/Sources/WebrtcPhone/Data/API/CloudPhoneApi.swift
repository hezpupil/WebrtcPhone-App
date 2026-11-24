import Foundation

/// REST API 封装。路由逐条对齐 Android 端 CloudPhoneApi.kt。
final class CloudPhoneApi {
    private let client: ApiClient
    var endpoint: ServerEndpoint { client.endpoint }

    init(client: ApiClient) { self.client = client }

    // MARK: 认证
    func login(username: String, password: String) async throws -> (token: String, username: String, role: String) {
        let data = try await client.post("/api/login", body: ["username": username, "password": password], auth: false)
        return try Parsers.loginResult(data)
    }
    func logout() async { try? await client.post("/api/logout", body: [:]) }
    func me() async throws -> Me { try Parsers.me(await client.get("/api/me")) }

    // MARK: 设备
    func devices() async throws -> [Device] { try Parsers.devices(await client.get("/devices")) }
    func deleteDevice(_ id: String) async throws { _ = try await client.delete("/api/devices/\(encode(id))") }
    func setDeviceAlias(_ id: String, alias: String) async throws {
        _ = try await client.post("/api/devices/alias", body: ["device_id": id, "alias": alias.trimmingCharacters(in: .whitespaces)])
    }

    // MARK: 标签
    func tags() async throws -> TagsPayload {
        try Parsers.tags(try JSONSerialization.jsonObject(with: await client.get("/api/tags")) as? [String: Any] ?? [:])
    }
    func saveTags(_ payload: TagsPayload) async throws {
        _ = try await client.post("/api/tags", body: Parsers.tagsToJson(payload))
    }

    // MARK: 快捷文本
    func quickTexts() async throws -> [QuickText] { try Parsers.quickTexts(await client.get("/api/quick_texts")) }
    func saveQuickTexts(_ list: [QuickText]) async throws {
        _ = try await client.post("/api/quick_texts", body: Parsers.quickTextsToJson(list))
    }

    // MARK: 服务器中转文件 / 任务
    func serverFiles() async throws -> [ServerFile] { try Parsers.serverFiles(await client.get("/api/files")) }
    func uploadServerFile(name: String, data: Data, progress: ((Double) -> Void)? = nil) async throws {
        _ = try await client.postRaw("/upload?name=\(encode(name))", body: data)
        progress?(1)
    }
    func serverFileSignedUrl(name: String) async throws -> String {
        let o = try JSONSerialization.jsonObject(with: await client.get("/api/files/url?name=\(encode(name))")) as? [String: Any] ?? [:]
        return o["url"] as? String ?? ""
    }
    func deleteServerFile(name: String) async throws {
        _ = try await client.delete("/api/files?name=\(encode(name))")
    }
    func createFileTask(type: ServerTaskType, targets: [String], payload: String, destPath: String) async throws -> String {
        let data = try await client.post("/api/tasks", body: [
            "type": type.rawValue, "targets": targets, "payload": payload, "dest_path": destPath,
        ] as [String: Any])
        let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return o["task_id"] as? String ?? ""
    }
    func taskDetails(_ taskId: String) async throws -> TaskDetails {
        let data = try await client.get("/api/tasks/details?task_id=\(encode(taskId))")
        return Parsers.taskDetails(try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }

    // MARK: 分享
    func createShare(_ req: ShareCreateRequest) async throws -> ShareCreated {
        let o = try await client.postEnvelope("/api/share/create", body: [
            "device_id": req.deviceId, "expire_seconds": req.expireSeconds,
            "access_mode": req.accessMode.rawValue, "password": req.password,
            "description": req.description, "allow_clipboard": req.allowClipboard,
            "allow_file_tx": req.allowFileTx, "custom_card_code": req.customCardCode,
        ] as [String: Any])
        guard let data = o["data"] as? [String: Any] else { throw ApiError.parse("分享响应格式错误") }
        return Parsers.shareCreated(data)
    }
    func shares(deviceId: String? = nil) async throws -> [Share] {
        var path = "/api/share/list"
        if let deviceId, !deviceId.trimmingCharacters(in: .whitespaces).isEmpty {
            path += "?device_id=\(encode(deviceId))"
        }
        let o = try await client.getEnvelope(path)
        guard let arr = o["data"] as? [Any] else { return [] }
        let data = try JSONSerialization.data(withJSONObject: arr)
        return try Parsers.shares(data)
    }
    func revokeShare(token: String) async throws {
        _ = try await client.postEnvelope("/api/share/revoke", body: ["token": token])
    }
    func extendShare(token: String, seconds: Int64) async throws {
        _ = try await client.postEnvelope("/api/share/extend", body: ["token": token, "extend_seconds": seconds])
    }
    func shareLink(token: String) -> String {
        client.endpoint.url("/share?token=" + encode(token))
    }

    // MARK: 用户管理（admin）
    func users() async throws -> [AdminUser] { try Parsers.adminUsers(await client.get("/api/admin/users")) }
    func createUser(_ req: AdminUserCreate) async throws {
        _ = try await client.post("/api/admin/users/create", body: [
            "username": req.username, "password": req.password, "role": req.role,
            "note": req.note, "expire_seconds": req.expireSeconds,
        ] as [String: Any])
    }
    func deleteUser(_ username: String) async throws {
        _ = try await client.post("/api/admin/users/delete", body: ["username": username])
    }
    func updateUserNote(_ username: String, note: String) async throws {
        _ = try await client.post("/api/admin/users/update_note", body: ["username": username, "note": note])
    }
    func resetUserPassword(_ username: String, password: String) async throws {
        _ = try await client.post("/api/admin/users/reset_password", body: ["username": username, "password": password])
    }
    func kickUser(_ username: String, deviceId: String = "") async throws {
        _ = try await client.post("/api/admin/users/kick", body: ["username": username, "device_id": deviceId])
    }
    func updateUser(_ username: String, expireSeconds: Int64, policy: UserPolicy? = nil) async throws {
        var body: [String: Any] = ["username": username, "expire_seconds": expireSeconds]
        if let policy { body["policy"] = policyJson(policy) }
        _ = try await client.post("/api/admin/users/update", body: body)
    }

    // MARK: 租约管理（admin）
    func adminLeases(user: String? = nil, device: String? = nil, status: String = "all") async throws -> [AdminLease] {
        var parts: [String] = []
        if let u = user, !u.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("user=\(encode(u))") }
        if let d = device, !d.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("device=\(encode(d))") }
        parts.append("status=\(encode(status))")
        return try Parsers.adminLeases(await client.get("/api/admin/leases?" + parts.joined(separator: "&")))
    }
    func createLease(_ req: LeaseCreateRequest) async throws -> AdminLease {
        var body: [String: Any] = [
            "username": req.username, "device_id": req.deviceId,
            "duration_seconds": req.durationSeconds, "note": req.note,
        ]
        if let p = req.policyOverride { body["policy_override"] = policyJson(p) }
        let data = try await client.post("/api/admin/leases/create", body: body)
        return Parsers.adminLease(try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }
    func extendLease(_ leaseId: String, seconds: Int64) async throws -> AdminLease {
        let data = try await client.post("/api/admin/leases/extend", body: ["lease_id": leaseId, "duration_seconds": seconds])
        return Parsers.adminLease(try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }
    func revokeLease(_ leaseId: String) async throws {
        _ = try await client.post("/api/admin/leases/revoke", body: ["lease_id": leaseId])
    }
    func updateLeaseNote(_ leaseId: String, note: String) async throws -> AdminLease {
        let data = try await client.post("/api/admin/leases/update", body: ["lease_id": leaseId, "note": note])
        return Parsers.adminLease(try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:])
    }

    // MARK: 缩略图
    func snapshotData(_ deviceId: String) -> URL {
        URL(string: client.endpoint.url("/snapshots/\(encode(deviceId)).jpg"))!
    }

    private func policyJson(_ p: UserPolicy) -> [String: Any] {
        ["forbid_bitrate": p.forbidBitrate, "forbid_fps": p.forbidFps,
         "forbid_resolution": p.forbidResolution, "forbid_audio": p.forbidAudio,
         "forbid_file_push": p.forbidFilePush, "forbid_terminal": p.forbidTerminal,
         "forbid_share": p.forbidShare]
    }

    private func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }
}
