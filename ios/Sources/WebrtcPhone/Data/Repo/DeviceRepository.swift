import Foundation
import SwiftUI
import Combine

/// 快照 UIImage + 版本（版本变化才触发 UI 重组，避免闪烁）
struct Snapshot: Equatable {
    let image: UIImage
    let version: UInt64
}

/// 设备大盘数据源。对齐 Android 端 DeviceRepository.kt：
/// WS 实时推送为主，HTTP 轮询兜底；标签写操作串行化避免丢更新。
@MainActor
final class DeviceRepository: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published private(set) var snapshots: [String: Snapshot] = [:]
    @Published private(set) var tags: TagsPayload = .empty
    @Published private(set) var me: Me?
    @Published private(set) var loading = false
    @Published private(set) var error: ApiError?
    @Published private(set) var socketState: SocketState = .idle

    private let session: AuthSession
    private let api: CloudPhoneApi
    private let socket: DashboardSocket
    private var activeTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var socketCancellable: AnyCancellable?
    private var loadedOnce = false
    private var tagSaveInFlight = 0
    private var etags: [String: String] = [:]
    private let snapshotSemaphore = AsyncSemaphore(limit: 3)

    init(session: AuthSession, api: CloudPhoneApi, socket: DashboardSocket) {
        self.session = session
        self.api = api
        self.socket = socket
    }

    var isAdmin: Bool { session.role == "admin" }

    func setActive(_ active: Bool) {
        if active {
            guard activeTask == nil else { return }
            activeTask = Task { [weak self] in
                guard let self else { return }
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.refresh(showLoading: !self.loadedOnce) }
                    group.addTask { await self.loadMeta() }
                    group.addTask { await self.pollLoop() }
                }
            }
            eventTask = Task { [weak self] in
                guard let self else { return }
                let publisher = self.socket.events
                // 订阅在主线程回调
                publisher.subscribe { event in
                    Task { @MainActor in
                        guard let event else { return }
                        self.onEvent(event)
                    }
                }
                self.socket.start()
            }
            socketCancellable = socket.$state
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in self?.socketState = state }
        } else {
            socket.stop()
            activeTask?.cancel(); activeTask = nil
            eventTask?.cancel(); eventTask = nil
        }
    }

    func close() { setActive(false) }

    func refresh(showLoading: Bool = true) async {
        if showLoading { loading = true }
        defer { loading = false }
        do {
            let list = try await api.devices()
            devices = list
            error = nil
            loadedOnce = true
            await refreshSnapshots(list)
        } catch let e as ApiError {
            error = e
        } catch {
            self.error = .network(error.localizedDescription)
        }
    }

    func loadMeta() async {
        if let me = try? await api.me() { self.me = me }
        if isAdmin, let t = try? await api.tags(), tagSaveInFlight == 0 { tags = t }
    }

    private func pollLoop() async {
        var tick = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            tick += 1
            if socketState != .connected && tick % 3 == 0 {
                await refresh(showLoading: false)
            } else if tick % 4 == 0 {
                await refreshSnapshots(devices)
            }
        }
    }

    private func onEvent(_ e: DashboardEvent) {
        switch e {
        case .devices(let list):
            devices = list
            loadedOnce = true
            let ids = Set(list.map { $0.id })
            snapshots = snapshots.filter { ids.contains($0.key) }
        case .snapshotData(let deviceId, let jpeg):
            Task { await applySnapshot(deviceId: deviceId, jpeg: jpeg, etag: nil) }
        case .snapshotUpdated(let deviceId, let hash):
            if hash.isEmpty || etags[deviceId]?.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) != hash {
                Task { await fetchSnapshot(deviceId) }
            }
        case .tags(let payload):
            if tagSaveInFlight == 0 { tags = payload }
        case .screenState(let deviceId, let state):
            if let i = devices.firstIndex(where: { $0.id == deviceId }) {
                devices[i].screenState = state
            }
        }
    }

    private func refreshSnapshots(_ list: [Device]) async {
        await withTaskGroup(of: Void.self) { group in
            for d in list where d.online {
                group.addTask { await self.fetchSnapshot(d.id) }
            }
        }
    }

    private func fetchSnapshot(_ deviceId: String) async {
        await snapshotSemaphore.wait()
        defer { snapshotSemaphore.signal() }
        guard let url = URL(string: api.endpoint.url("/snapshots/\(deviceId).jpg")) else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization")
        if let etag = etags[deviceId] { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 304 { return }
            await applySnapshot(deviceId: deviceId, jpeg: data,
                                etag: (response as? HTTPURLResponse)?.allHeaderFields["ETag"] as? String)
        } catch {
            // 快照获取失败静默忽略
        }
    }

    private func applySnapshot(deviceId: String, jpeg: Data, etag: String?) async {
        guard let image = decodeThumb(jpeg) else { return }
        if let etag { etags[deviceId] = etag }
        snapshots[deviceId] = Snapshot(image: image, version: UInt64(Date().timeIntervalSince1970 * 1_000_000))
    }

    private func decodeThumb(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let target: CGFloat = 360
        if image.size.width <= target { return image }
        let scale = target / image.size.width
        let size = CGSize(width: target, height: image.size.height * scale)
        UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    // MARK: 设备 / 标签管理
    func setDeviceAlias(_ deviceId: String, alias: String) async throws {
        try await api.setDeviceAlias(deviceId, alias: alias)
        if let i = devices.firstIndex(where: { $0.id == deviceId }) { devices[i].alias = alias.trimmingCharacters(in: .whitespaces) }
    }

    func deleteDevice(_ deviceId: String) async throws {
        try await api.deleteDevice(deviceId)
        devices.removeAll { $0.id == deviceId }
    }

    func saveTags(_ payload: TagsPayload) async throws { try await mutateTags { _ in payload } }
    func upsertTag(_ tag: Tag) async throws { try await mutateTags { TagOps.upsert($0, tag) } }
    func deleteTag(_ tagId: String) async throws { try await mutateTags { TagOps.delete($0, tagId) } }
    func setDeviceTags(_ deviceId: String, _ tagIds: [String]) async throws {
        try await mutateTags { TagOps.setDeviceTags($0, deviceId, tagIds) }
    }

    /// 串行执行，锁内基于最新 tags 计算；乐观更新后 POST，失败回滚。
    private func mutateTags(_ transform: (TagsPayload) -> TagsPayload) async throws {
        let old = tags
        let next = transform(old)
        guard next != old else { return }
        tagSaveInFlight += 1
        tags = next
        do {
            try await api.saveTags(next)
        } catch {
            tags = old
            throw error
        } finally {
            tagSaveInFlight -= 1
        }
    }
}

/// 轻量异步信号量
final class AsyncSemaphore {
    private let lock = NSLock()
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { value = limit }
    func wait() async {
        await withCheckedContinuation { cont in
            lock.lock()
            if value > 0 { value -= 1; lock.unlock(); cont.resume() }
            else { waiters.append(cont); lock.unlock() }
        }
    }
    func signal() {
        lock.lock()
        if let first = waiters.first { waiters.removeFirst(); lock.unlock(); first.resume() }
        else { value += 1; lock.unlock() }
    }
}
