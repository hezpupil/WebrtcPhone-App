import SwiftUI

struct StreamControlBar: View {
    @Binding var showFiles: Bool
    @Binding var showTerminal: Bool
    @Binding var showKeybar: Bool
    let session: RtcSession?

    var body: some View {
        HStack(spacing: 4) {
            ControlButton(icon: "arrow.up", label: "主页") { _ = session?.input.press(Keys.home) }
            ControlButton(icon: "arrow.left", label: "返回") { _ = session?.input.press(Keys.back) }
            ControlButton(icon: "rectangle.and.hand.point.up.left", label: "桌面") {
                _ = session?.input.press(Keys.appSwitch)
            }
            Divider().frame(height: 28).opacity(0.3)
            ControlButton(icon: "doc.on.doc", label: "剪贴板") {
                UIPasteboard.general.string.flatMap { session?.clipboard.setClipboard($0, paste: true) }
            }
            ControlButton(icon: "folder", label: "文件") { showFiles = true }
            ControlButton(icon: "terminal", label: "终端") { showTerminal = true }
            ControlButton(icon: "keyboard", label: "按键") { showKeybar.toggle() }
            ControlButton(icon: "camera.fill", label: "截图") { _ = session?.input.press(Keys.screenshot) }
        }
        .padding(.horizontal, 8)
        .sheet(isPresented: $showKeybar) { KeybarView(session: session) }
    }
}

struct ControlButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.title3)
                Text(label).font(.caption2)
            }
            .frame(minWidth: 52, minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

/// 虚拟按键栏：常用 Android KeyEvent
struct KeybarView: View {
    let session: RtcSession?
    @Environment(\.dismiss) private var dismiss

    private let keys: [(String, Int)] = [
        ("返回", Keys.back), ("主页", Keys.home), ("多任务", Keys.appSwitch),
        ("电源", Keys.power), ("音量+", Keys.volumeUp), ("音量-", Keys.volumeDown),
        ("Tab", Keys.tab), ("Enter", Keys.enter), ("删除", Keys.del),
        ("Esc", Keys.escape), ("播放", Keys.mediaPlayPause), ("通知", Keys.notification),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 12) {
                    ForEach(keys, id: \.0) { name, code in
                        Button { _ = session?.input.press(code) } label: {
                            Text(name).frame(maxWidth: .infinity).padding(12)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("虚拟按键")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
