import Foundation
import SwiftUI
import Combine

/// 手写依赖容器（对齐 Android 端 AppContainer）。进程级对象共享，会话级对象按登录创建。
@MainActor
final class AppContainer: ObservableObject {
    let httpFactory: HttpClientFactory
    let session: SessionRepository
    let settings: SettingsRepository
    let engine: RtcEngine

    @Published private(set) var userScope: UserScope?
    private var sessionCancellable: AnyCancellable?

    init(defaults: UserDefaults = .standard) {
        self.httpFactory = HttpClientFactory()
        self.session = SessionRepository(factory: httpFactory, defaults: defaults)
        self.settings = SettingsRepository(defaults: defaults)
        self.engine = .shared
        engine.warmUp()
        bindSession()
    }

    private func bindSession() {
        sessionCancellable = session.$session
            .receive(on: DispatchQueue.main)
            .sink { [weak self] auth in
                guard let self else { return }
                if let auth, let api = self.session.api(),
                   let endpoint = ServerEndpoint.parse(auth.serverUrl) {
                    self.userScope = UserScope(session: auth, api: api, httpFactory: self.httpFactory,
                                               endpoint: endpoint, settings: self.settings)
                } else {
                    self.userScope?.close()
                    self.userScope = nil
                }
            }
    }
}

/// 单个登录会话持有的数据源（会话级）
@MainActor
final class UserScope: ObservableObject {
    let session: AuthSession
    let api: CloudPhoneApi
    let endpoint: ServerEndpoint
    let settings: SettingsRepository

    @Published private(set) var devices: DeviceRepository!
    @Published private(set) var quickTexts: QuickTextRepository!
    @Published private(set) var serverFiles: ServerFileRepository!
    @Published private(set) var dashboard: DashboardSocket!
    @Published private(set) var sessionManager: SessionManager?

    // 子 Repository 的 @Published 不会自动冒泡到父 ObservableObject，
    // 必须显式转发，否则设备列表/统计等 UI 在数据到达时不刷新
    private var bubbleBag: Set<AnyCancellable> = []

    init(session: AuthSession, api: CloudPhoneApi, httpFactory: HttpClientFactory,
         endpoint: ServerEndpoint, settings: SettingsRepository) {
        self.session = session
        self.api = api
        self.endpoint = endpoint
        self.settings = settings
        let socket = DashboardSocket(httpFactory: httpFactory, endpoint: endpoint,
                                     tokenProvider: { session.token },
                                     onUnauthorized: {})
        self.dashboard = socket
        self.devices = DeviceRepository(session: session, api: api, socket: socket,
                                        httpFactory: httpFactory)
        self.quickTexts = QuickTextRepository(api: api)
        self.serverFiles = ServerFileRepository(api: api, endpoint: endpoint)
        self.sessionManager = SessionManager(engine: .shared, httpFactory: httpFactory)
        sessionManager?.setAutoReconnect(settings.app.autoReconnect)
        devices.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bubbleBag)
        quickTexts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bubbleBag)
        serverFiles.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bubbleBag)
        dashboard.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bubbleBag)
        sessionManager?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bubbleBag)
    }

    func close() {
        devices.close()
        sessionManager?.close()
        sessionManager = nil
    }
}
