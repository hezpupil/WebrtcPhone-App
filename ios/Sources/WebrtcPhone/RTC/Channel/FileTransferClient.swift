import Foundation

enum TransferKind: String { case upload, download }
enum TransferState: String {
    case queued, preparing, active, done, failed, canceled
    var finished: Bool { self == .done || self == .failed || self == .canceled }
}

struct Transfer: Identifiable, Equatable {
    let id: Int64
    var kind: TransferKind
    var name: String
    var remotePath: String
    var state: TransferState = .queued
    var loaded: Int64 = 0
    var total: Int64 = 0
    var error: String?
    var installAfter = false
    var speed: Int64 = 0
    var progress: Float { total > 0 ? min(max(Float(loaded) / Float(total), 0), 1) : 0 }
}

struct InstallStatus: Equatable {
    var status: String
    var message: String
}

enum FileOpError: LocalizedError, Equatable {
    case channelNotReady
    case deviceNoResponse(String)
    case operation(String)

    var errorDescription: String? {
        switch self {
        case .channelNotReady: return "文件通道未就绪"
        case .deviceNoResponse(let m): return m
        case .operation(let m): return m
        }
    }
}

/// 一次性等待值（线程安全，支持超时）。
private final class Deferred<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var resolved: Result<T, Error>?
    private var timedOut = false

    func wait(timeout: TimeInterval) async throws -> T {
        let value: T = try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let r = resolved {
                lock.unlock()
                cont.resume(with: r)
                return
            }
            continuation = cont
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                if self.continuation != nil {
                    self.continuation = nil
                    self.timedOut = true
                    self.lock.unlock()
                    cont.resume(throwing: FileOpError.deviceNoResponse("设备无响应"))
                } else { self.lock.unlock() }
            }
        }
        return value
    }

    func resolve(_ value: T) {
        lock.lock()
        guard !timedOut else { lock.unlock(); return }
        if let c = continuation { continuation = nil; lock.unlock(); c.resume(returning: value) }
        else { resolved = .success(value); lock.unlock() }
    }

    func fail(_ error: Error) {
        lock.lock()
        guard !timedOut else { lock.unlock(); return }
        if let c = continuation { continuation = nil; lock.unlock(); c.resume(throwing: error) }
        else { resolved = .failure(error); lock.unlock() }
    }
}

/// file-channel 协议客户端运行时。对齐 Android 端 FileTransferClient.kt：
///   list/mkdir/delete → *_reply
///   upload_start → upload_reply → 16KB 二进制块 → upload_ack(finished)
///   download_start → download_reply(size) → 二进制块直到收满 size
final class FileTransferClient: ObservableObject {
    @Published private(set) var open = false
    @Published private(set) var transfers: [Transfer] = []

    private let channel: SafeChannel
    private let idSeq = AtomicInt64(0)
    private let requestSeq = AtomicInt64(0)
    private let lock = NSLock()

    private var pendingReply: (expected: String, deferred: Deferred<[String: Any]>)?
    private var activeUploadId: Int64 = -1
    private var activeDownloadId: Int64 = -1
    private var uploadReply = Deferred<[String: Any]>()
    private var uploadFinished = Deferred<[String: Any]>()
    private var downloadReply = Deferred<[String: Any]>()
    private var downloadFinished = Deferred<[String: Any]>()
    private var downloadDest: URL?
    private var downloadStartedAt = Date()
    private var lastProgressAt = Date()
    private var installEventsHandler: ((InstallStatus) -> Void)?

    init(channel: SafeChannel) {
        self.channel = channel
        open = channel.isOpen
        channel.observe(message: { [weak self] data, binary in
            guard let self else { return }
            if binary { self.onChunk(data) }
            else if let text = String(data: data, encoding: .utf8) { self.onText(text) }
        }, state: { [weak self] state in
            guard let self else { return }
            let isOpen = state == .open
            DispatchQueue.main.async { self.open = isOpen }
        })
    }

    func onInstallEvent(_ handler: @escaping (InstallStatus) -> Void) { installEventsHandler = handler }

    // MARK: 目录操作
    func list(_ path: String) async throws -> [RemoteFile] {
        let reply = try await request("list_reply", FileTransferProtocol.list(path))
        guard bool(reply["success"]) else {
            throw FileOpError.operation(str(reply["error"]) ?? "读取目录失败")
        }
        guard let (files, err) = FileTransferProtocol.parseList(reply) else {
            throw FileOpError.operation("读取目录失败")
        }
        if let err { throw FileOpError.operation(err) }
        return files.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    func mkdir(_ path: String) async throws {
        let reply = try await request("mkdir_reply", FileTransferProtocol.mkdir(path))
        guard bool(reply["success"]) else { throw FileOpError.operation(str(reply["error"]) ?? "操作失败") }
    }

    func delete(_ path: String) async throws {
        let reply = try await request("delete_reply", FileTransferProtocol.delete(path))
        guard bool(reply["success"]) else { throw FileOpError.operation(str(reply["error"]) ?? "操作失败") }
    }

    func installApk(_ remotePath: String) -> Bool {
        channel.send(FileTransferProtocol.installApk(remotePath, requestId: String(requestSeq.next())))
    }

    private func request(_ expected: String, _ cmd: String) async throws -> [String: Any] {
        let deferred = Deferred<[String: Any]>()
        lock.lock()
        pendingReply = (expected, deferred)
        lock.unlock()
        guard channel.send(cmd) else {
            lock.lock(); pendingReply = nil; lock.unlock()
            throw FileOpError.channelNotReady
        }
        return try await deferred.wait(timeout: 15)
    }

    // MARK: 上传
    func upload(src: URL, name: String, remotePath: String, size: Int64,
                installAfter: Bool = false) async throws {
        guard channel.isOpen else { throw FileOpError.channelNotReady }
        let id = idSeq.next()
        addTransfer(Transfer(id: id, kind: .upload, name: name, remotePath: remotePath,
                             total: size, installAfter: installAfter))
        do {
            patch(id, state: .preparing)
            let sha = try FileTransferProtocol.sha256(of: src)
            patch(id, state: .active, loaded: 0, total: size)
            activeUploadId = id
            // 先构造命令再发送，避免 reply  races
            let cmd = FileTransferProtocol.uploadStart(path: remotePath, size: size,
                                                        sha256: sha, installOnFinish: installAfter)
            let reply = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.global().async {
                    guard self.channel.send(cmd) else {
                        cont.resume(throwing: FileOpError.channelNotReady); return
                    }
                    cont.resume(returning: ())
                }
            }
            let r = try await uploadReply.wait(timeout: 15)
            _ = reply
            guard bool(r["success"]) else { throw FileOpError.operation(str(r["error"]) ?? "设备拒绝上传") }

            let handle = try FileHandle(forReadingFrom: src)
            defer { try? handle.close() }
            var sent: Int64 = 0
            let started = Date()
            while sent < size {
                while channel.bufferedAmount() > FileTransferProtocol.flowControlBytes {
                    guard channel.isOpen else { throw FileOpError.channelNotReady }
                    Thread.sleep(forTimeInterval: 0.004)
                }
                let chunk = (try handle.read(upToCount: FileTransferProtocol.chunkSize)) ?? Data()
                if chunk.isEmpty { break }
                guard channel.sendBytes(chunk, binary: true) else { throw FileOpError.channelNotReady }
                sent += Int64(chunk.count)
                lastProgressAt = Date()
                patch(id, loaded: sent, speed: sent / Int64(max(1, Date().timeIntervalSince(started))))
            }
            let ack = try await waitForProgress(deferred: uploadFinished)
            guard bool(ack["success"] ?? true) else { throw FileOpError.operation(str(ack["error"]) ?? "文件校验失败") }
            activeUploadId = -1
            patch(id, state: .done, loaded: size)
        } catch {
            channel.send(FileTransferProtocol.uploadCancel(remotePath))
            channel.send(FileTransferProtocol.delete(remotePath))
            activeUploadId = -1
            patch(id, state: .failed, error: error.localizedDescription)
            throw error
        }
    }

    // MARK: 下载
    func download(remotePath: String, dest: URL, name: String, size: Int64) async throws {
        guard channel.isOpen else { throw FileOpError.channelNotReady }
        let id = idSeq.next()
        addTransfer(Transfer(id: id, kind: .download, name: name, remotePath: remotePath, total: size))
        do {
            try Data().write(to: dest, options: .atomic)
            downloadDest = dest
            activeDownloadId = id
            downloadStartedAt = Date()
            patch(id, state: .active)
            guard channel.send(FileTransferProtocol.downloadStart(path: remotePath,
                                                                    requestId: String(requestSeq.next()))) else {
                throw FileOpError.channelNotReady
            }
            let r = try await downloadReply.wait(timeout: 15)
            guard bool(r["success"]) else { throw FileOpError.operation(str(r["error"]) ?? "下载失败") }
            let total = int64(r["size"])
            patch(id, total: total)
            if total > 0 { _ = try await waitForProgress(deferred: downloadFinished) }
            activeDownloadId = -1
            patch(id, state: .done, loaded: total)
        } catch {
            channel.send(FileTransferProtocol.downloadCancel(remotePath))
            try? FileManager.default.removeItem(at: dest)
            activeDownloadId = -1
            patch(id, state: .failed, error: error.localizedDescription)
            throw error
        }
    }

    func cancel(id: Int64) { patch(id, state: .canceled, error: "已取消") }

    private func waitForProgress(deferred: Deferred<[String: Any]>) async throws -> [String: Any] {
        while true {
            let r = try await deferred.wait(timeout: 30)
            return r
        }
    }

    // MARK: 入站消息
    private func onText(_ text: String) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = str(o["type"]) else { return }
        lock.lock()
        if let p = pendingReply, p.expected == type {
            pendingReply = nil; lock.unlock()
            p.deferred.resolve(o); return
        }
        lock.unlock()
        switch type {
        case "upload_reply" where activeUploadId >= 0:
            uploadReply.resolve(o)
        case "upload_ack" where activeUploadId >= 0:
            lastProgressAt = Date()
            if bool(o["finished"]) { uploadFinished.resolve(o) }
        case "download_reply" where activeDownloadId >= 0:
            downloadReply.resolve(o)
        case "install_status":
            installEventsHandler?(InstallStatus(status: str(o["status"]) ?? "",
                                                 message: str(o["message"]) ?? ""))
        default:
            break
        }
    }

    private func onChunk(_ data: Data) {
        guard activeDownloadId >= 0, let dest = downloadDest,
              let handle = try? FileHandle(forWritingTo: dest) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        lastProgressAt = Date()
        let id = activeDownloadId
        var total: Int64 = 0
        var loaded: Int64 = 0
        DispatchQueue.main.sync {
            if let t = transfers.first(where: { $0.id == id }) { total = t.total; loaded = t.loaded }
        }
        loaded += Int64(data.count)
        patch(id, loaded: loaded, speed: loaded / Int64(max(1, Date().timeIntervalSince(downloadStartedAt))))
        if total > 0 && loaded >= total { downloadFinished.resolve(["success": true]) }
    }

    // MARK: 状态
    private func addTransfer(_ t: Transfer) { DispatchQueue.main.async { self.transfers.append(t) } }
    private func patch(_ id: Int64, state: TransferState? = nil, loaded: Int64? = nil,
                       total: Int64? = nil, error: String? = nil, speed: Int64? = nil) {
        DispatchQueue.main.async {
            guard let i = self.transfers.firstIndex(where: { $0.id == id }) else { return }
            var t = self.transfers[i]
            if let s = state { t.state = s }
            if let l = loaded { t.loaded = l }
            if let tt = total { t.total = tt }
            if let e = error { t.error = e }
            if let sp = speed { t.speed = sp }
            self.transfers[i] = t
        }
    }
}

// MARK: - 工具
private final class AtomicInt64 {
    private let lock = NSLock()
    private var value: Int64
    init(_ v: Int64 = 0) { value = v }
    func next() -> Int64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}

private func str(_ v: Any?) -> String? { v as? String }
private func bool(_ v: Any?) -> Bool { (v as? NSNumber)?.boolValue ?? (v as? Bool) ?? false }
private func int64(_ v: Any?) -> Int64 { (v as? NSNumber)?.int64Value ?? 0 }
