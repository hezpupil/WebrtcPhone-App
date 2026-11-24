import Foundation

/// 一次服务器中转操作（上传 / 下发）的 UI 状态
struct ServerOp: Identifiable, Equatable {
    enum Kind: String { case upload, dispatch }
    enum State: String { case active, done, failed }
    let id: Int64
    var name: String
    var kind: Kind
    var state: State = .active
    var loaded: Int64 = 0
    var total: Int64 = 0
    var message = ""
    var progress: Float { total > 0 ? min(max(Float(loaded) / Float(total), 0), 1) : 0 }
}

/// 服务器中转文件模式：本地 →(POST /upload)→ 服务器盘 →(POST /api/tasks)→ 设备。
@MainActor
final class ServerFileRepository: ObservableObject {
    @Published private(set) var files: [ServerFile] = []
    @Published private(set) var loading = false
    @Published private(set) var ops: [ServerOp] = []
    @Published private(set) var task: TaskDetails?
    @Published private(set) var dispatching = false

    private let api: CloudPhoneApi
    private let endpoint: ServerEndpoint
    private var idSeq: Int64 = 0

    init(api: CloudPhoneApi, endpoint: ServerEndpoint) {
        self.api = api
        self.endpoint = endpoint
    }

    func refresh() async {
        loading = true
        defer { loading = false }
        files = (try? await api.serverFiles()) ?? files
    }

    func delete(_ name: String) async throws {
        try await api.deleteServerFile(name: name)
        files.removeAll { $0.name == name }
    }

    func upload(url: URL, name: String, size: Int64) async throws {
        let id = nextId()
        ops.append(ServerOp(id: id, name: name, kind: .upload, total: size))
        do {
            let data = try Data(contentsOf: url)
            try await api.uploadServerFile(name: name, data: data) { progress in
                Task { @MainActor in self.patch(id, loaded: Int64(Double(size) * progress)) }
            }
            patch(id, state: .done, loaded: size)
            await refresh()
        } catch {
            patch(id, state: .failed, message: error.localizedDescription)
            throw error
        }
    }

    /// 单设备下发，轮询子任务直到结束
    @discardableResult
    func dispatch(_ file: ServerFile, deviceId: String, destPath: String? = nil) async throws -> SubTaskStatus {
        let id = nextId()
        ops.append(ServerOp(id: id, name: file.name, kind: .dispatch, message: "准备下发…"))
        do {
            let type = ServerFileOps.taskTypeFor(file.name)
            let signed = try await api.serverFileSignedUrl(name: file.name)
            let payload = ServerFileOps.absoluteUrl(httpBase: endpoint.httpBase, signedPath: signed)
            let dest = type == .pushFile ? (destPath?.trimmingCharacters(in: .whitespaces).isEmpty == false
                                           ? destPath! : ServerFileOps.defaultDestPath(file.name)) : ""
            patch(id, message: type == .install ? "正在安装…" : "正在下发…")
            let taskId = try await api.createFileTask(type: type, targets: [deviceId], payload: payload, destPath: dest)
            let deadline = Date().addingTimeInterval(120)
            var last: SubTaskStatus?
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 700 * 1_000_000)
                guard let details = try? await api.taskDetails(taskId),
                      let sub = details.devices[deviceId] else { continue }
                last = sub
                patch(id, message: label(sub.status))
                if sub.finished {
                    patch(id, state: sub.ok ? .done : .failed,
                          message: sub.ok ? "完成" : (sub.result.isEmpty ? "失败" : sub.result))
                    return sub
                }
            }
            patch(id, state: .failed, message: "任务超时")
            return last ?? SubTaskStatus(deviceId: deviceId, status: "failed", progress: 0, result: "任务超时")
        } catch {
            patch(id, state: .failed, message: error.localizedDescription)
            throw error
        }
    }

    /// 批量下发：一次任务到多台设备，通过 task 暴露每台状态
    func dispatchBatch(_ file: ServerFile, deviceIds: [String], destPath: String? = nil) async throws {
        guard !deviceIds.isEmpty else { return }
        dispatching = true
        defer { dispatching = false }
        let type = ServerFileOps.taskTypeFor(file.name)
        let signed = try await api.serverFileSignedUrl(name: file.name)
        let payload = ServerFileOps.absoluteUrl(httpBase: endpoint.httpBase, signedPath: signed)
        let dest = type == .pushFile ? (destPath ?? ServerFileOps.defaultDestPath(file.name)) : ""
        let taskId = try await api.createFileTask(type: type, targets: deviceIds, payload: payload, destPath: dest)
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 700 * 1_000_000)
            if let details = try? await api.taskDetails(taskId) {
                task = details
                if details.devices.values.allSatisfy({ $0.finished }) { break }
            }
        }
    }

    func clearFinished() { ops.removeAll { $0.state != .active } }
    func clearTask() { task = nil }

    private func nextId() -> Int64 { idSeq += 1; return idSeq }
    private func patch(_ id: Int64, state: ServerOp.State? = nil, loaded: Int64? = nil, message: String? = nil) {
        guard let i = ops.firstIndex(where: { $0.id == id }) else { return }
        if let s = state { ops[i].state = s }
        if let l = loaded { ops[i].loaded = l }
        if let m = message { ops[i].message = m }
    }
    private func label(_ status: String) -> String {
        switch status.lowercased() {
        case "queued": return "排队中"; case "running": return "处理中"
        case "success", "done", "completed": return "完成"; case "failed", "error": return "失败"
        default: return status
        }
    }
}
