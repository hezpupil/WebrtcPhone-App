import Foundation

/// 快捷文本（文本下发模板），按用户存储在服务端，与 Web 端共享。
@MainActor
final class QuickTextRepository: ObservableObject {
    @Published private(set) var items: [QuickText] = []
    private let api: CloudPhoneApi
    private var loaded = false

    init(api: CloudPhoneApi) { self.api = api }

    func load(force: Bool = false) async {
        guard force || !loaded else { return }
        do {
            items = try await api.quickTexts()
            loaded = true
        } catch {
            loaded = false
        }
    }

    func upsert(title: String, content: String, autoEnter: Bool, id: String? = nil) async throws {
        let list = items
        let next: [QuickText]
        if let id, list.contains(where: { $0.id == id }) {
            next = list.map { $0.id == id ? QuickText(id: $0.id, title: title, content: content,
                                                       autoEnter: autoEnter, createdAt: $0.createdAt) : $0 }
        } else {
            next = list + [QuickText(id: "qt_" + String(UUID().uuidString.prefix(8)),
                                     title: title, content: content, autoEnter: autoEnter,
                                     createdAt: Int64(Date().timeIntervalSince1970 * 1000))]
        }
        try await save(next)
    }

    func delete(_ id: String) async throws {
        try await save(items.filter { $0.id != id })
    }

    private func save(_ next: [QuickText]) async throws {
        let old = items
        items = next
        do { try await api.saveQuickTexts(next) }
        catch { items = old; throw error }
    }
}
