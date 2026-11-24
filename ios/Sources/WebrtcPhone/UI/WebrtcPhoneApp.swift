import SwiftUI

@main
struct WebrtcPhoneApp: App {
    @StateObject private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

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
