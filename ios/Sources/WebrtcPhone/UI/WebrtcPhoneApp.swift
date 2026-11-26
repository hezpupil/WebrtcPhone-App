import SwiftUI

@main
struct WebrtcPhoneApp: App {
    @StateObject private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CrashReporter.install()
        Trail.mark("build=\(AppBuild.tag) app-start")
        // WebRTC 工厂启动时预热（创建耗时长且可能失败，埋点定位；主线程创建最稳妥）
        DispatchQueue.main.async {
            RtcEngine.shared.warmUp()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(container)
                .environmentObject(container.settings)
                .onChange(of: scenePhase) { phase in
                    if phase != .active { container.userScope?.devices.setActive(false) }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var container: AppContainer

    var body: some View {
        Group {
            if container.session.session != nil, let scope = container.userScope {
                HomeView()
                    .environmentObject(scope)
            } else {
                LoginView()
            }
        }
        .overlay(alignment: .top) {
            if let reason = container.session.logoutReason {
                Text(reason)
                    .font(.caption)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            container.session.consumeLogoutReason()
                        }
                    }
            }
        }
    }
}
