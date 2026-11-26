import SwiftUI
import WebRTC
import UIKit

/// 视频渲染视图（承载 RTCMTLVideoView），页面重建时通过 SessionManager.attach 复用会话。
struct VideoRenderView: UIViewRepresentable {
    let renderer: RTCMTLVideoView

    func makeUIView(context: Context) -> RTCMTLVideoView { renderer }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}

/// 独立投屏页（对齐 Android StreamScreen）：
/// 整屏视频 + 底部虚拟导航键 + 可拖动悬浮球 + 左侧切换设备把手 + 工具/文本/画质/信息/终端面板。
struct StreamView: View {
    let initialDevice: Device
    @ObservedObject var scope: UserScope
    @ObservedObject var container: AppContainer
    /// 独立投屏页的关闭回调（条件渲染替换视图树时由宿主提供）
    var onClose: (() -> Void)? = nil

    @State private var currentDevice: Device
    @State private var rendererBox: RTCMTLVideoView?
    @State private var phase: ConnectionPhase = .signaling
    @State private var videoSize: (Int, Int)?
    @State private var firstFrame = false
    @State private var stats = StreamStats()
    @State private var deviceInfo: DeviceInfo?
    @State private var panel: StreamPanel?
    @State private var showTerminal = false
    @State private var keyboardMode = false
    @State private var fullscreen = false
    @State private var drawerOpen = false
    @State private var viewOnly = false
    @State private var audioOn = true
    @State private var toastText = ""
    @State private var toastTask: Task<Void, Never>?
    @StateObject private var kbObserver = KeyboardHeightObserver()
    @Environment(\.dismiss) private var dismiss

    init(device: Device, scope: UserScope, container: AppContainer, onClose: (() -> Void)? = nil) {
        self.initialDevice = device
        self.scope = scope
        self.container = container
        self.onClose = onClose
        _currentDevice = State(initialValue: device)
    }

    private var session: RtcSession? { scope.sessionManager?.session }

    /// 退出投屏页：条件渲染模式下回调宿主关闭，presentation 模式回退 dismiss
    private func closePage() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var connected: Bool { phase == .connected || phase == .interrupted }
    private var isGuest: Bool {
        if case .share? = session?.target.auth { return true }
        return false
    }
    private var canSwitchDevices: Bool { session?.target.isGuest == false }

    // 对齐 Android showNav = showNavBar && !isCamera && !viewOnly && !fullscreen
    private var showNavKeys: Bool { container.settings.app.showNavBar && !viewOnly && !fullscreen }

    /// 设备逻辑分辨率（触控坐标系），画面旋转时与视频方向不一致则宽高互换
    private var touchDisplaySize: (Int, Int)? {
        guard let d = deviceInfo?.primaryDisplay else { return nil }
        return (d.width, d.height)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 主画面列：视频 + 虚拟导航键（对齐 Android Column + NavKeys）
            VStack(spacing: 0) {
                ZStack {
                    if let renderer = rendererBox {
                        VideoRenderView(renderer: renderer)
                    }
                    TouchLayer(session: session, videoSize: videoSize,
                               displaySize: touchDisplaySize,
                               viewOnly: viewOnly,
                               haptics: container.settings.app.haptics)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showNavKeys {
                    NavKeysBar(onKey: { press($0) }, onLongKey: { longPressKey($0) })
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 顶部提示（对齐 Android Banner）
            VStack {
                if viewOnly { StreamBanner(text: "仅观看模式", warning: false) }
                if phase == .interrupted { StreamBanner(text: "网络波动，正在恢复…", warning: true) }
                Spacer()
            }
            .padding(.top, 8)

            // 性能浮层（左上角）
            if container.settings.app.showStats && connected {
                VStack {
                    HStack { StatsHud(stats: stats); Spacer() }
                    Spacer()
                }
                .padding(8)
            }

            // 常驻左侧把手：切换设备入口（全屏模式下隐藏）
            if canSwitchDevices && !keyboardMode && !showTerminal && !drawerOpen && !fullscreen {
                VStack {
                    Spacer()
                    HStack { DrawerHandle { openDrawer() }; Spacer() }
                    Spacer()
                }
            }

            // 可拖动悬浮球：点击工具面板，长按设备抽屉
            if !showTerminal && !keyboardMode {
                FloatingBall(
                    onClick: { panel = .tools },
                    onLongClick: canSwitchDevices ? { openDrawer() } : nil
                )
            }

            // 键盘输入条（键盘弹出时画面不动，仅输入条上移）
            if keyboardMode {
                VStack {
                    Spacer()
                    KeyboardBar(session: session, onDone: { keyboardMode = false })
                        .offset(y: -kbObserver.height)
                }
                .ignoresSafeArea(.keyboard)
            }

            // 终端底部面板（45% 高度，对齐 Android TerminalPanel；键盘弹出时随避让上移）
            if showTerminal, let terminal = session?.terminal.value {
                VStack {
                    Spacer()
                    TerminalBottomPanel(channel: terminal, onClose: { showTerminal = false })
                        .frame(height: UIScreen.main.bounds.height * 0.45)
                        .transition(.move(edge: .bottom))
                }
            }

            // 设备切换抽屉
            if drawerOpen {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture { closeDrawer() }
                HStack(spacing: 0) {
                    DeviceDrawerView(scope: scope,
                                     currentId: currentDevice.id,
                                     onSelect: { switchDevice($0) },
                                     onClose: { closeDrawer() },
                                     onRefresh: { Task { await scope.devices.refresh() } })
                        .frame(width: 320)
                    Spacer()
                }
                .transition(.move(edge: .leading))
                .zIndex(10)
            }

            // 等待/错误覆盖层（对齐 Android ConnectingOverlay / FailedOverlay）
            if case .failed(let message, let retryable, _) = phase {
                FailedOverlay(message: message, retryable: retryable,
                              onRetry: { restart() }, onExit: { closePage() })
                    .zIndex(20)
            } else if phase == .closed {
                FailedOverlay(message: "会话已结束", retryable: true,
                              onRetry: { restart() }, onExit: { closePage() })
                    .zIndex(20)
            } else if !firstFrame {
                ConnectingOverlay(phaseLabel: connectPhaseLabel,
                                  deviceName: currentDevice.displayName,
                                  onExit: { closePage() })
                    .zIndex(20)
            }

            // Toast
            if !toastText.isEmpty {
                VStack { Spacer(); StreamToast(text: toastText) }
                    .padding(.bottom, showNavKeys ? 56 : 24)
                    .allowsHitTesting(false)
                    .zIndex(30)
            }
        }
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.2), value: drawerOpen)
        .sheet(item: $panel) { p in sheetContent(p) }
        .onAppear {
            // 对齐 Android：投屏期间停掉设备大盘轮询/快照拉取，避免与视频流抢带宽
            scope.devices.setActive(false)
            // 屏幕常亮（对齐 Android FLAG_KEEP_SCREEN_ON）
            UIApplication.shared.isIdleTimerDisabled = true
            if container.settings.stream.audio {
                // 用户想开声音：从未询问过权限时先触发一次系统弹窗（授予后下次连接生效）
                RtcSession.requestMicPermissionIfNeeded()
            }
            Task { await scope.quickTexts.load() }
            connect()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            scope.devices.setActive(true)
            if let renderer = rendererBox { scope.sessionManager?.detach(renderer) }
        }
        // 侧边栏打开期间每 10 秒刷新设备列表（对齐 Android openDrawer 轮询）
        .task(id: drawerOpen) {
            guard drawerOpen else { return }
            while !Task.isCancelled {
                await scope.devices.refresh()
                await scope.devices.loadMeta()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    private var connectPhaseLabel: String {
        switch phase {
        case .signaling: return "连接服务器…"
        case .waitingOffer: return "等待设备响应…"
        case .waitingProjection: return "等待手机用户确认共享屏幕…"
        case .negotiating: return "建立加密通道…"
        case .connected: return "等待首帧画面…"
        case .interrupted: return "网络波动，正在恢复…"
        case .failed(let m, _, _): return m
        case .closed: return "会话已结束"
        }
    }

    // MARK: - 连接

    private func connect() {
        var target = makeTarget()
        // Metal 视图只在首次进入时创建一次；避免 SwiftUI 结构体重建时反复创建 RTCMTLVideoView
        if rendererBox == nil {
            rendererBox = RTCMTLVideoView()
            Trail.mark("sv:renderer-created")
        }
        guard let renderer = rendererBox else { return }
        Trail.mark("sv:connect dev=\(currentDevice.id)")
        scope.sessionManager?.attach(renderer)
        let s = scope.sessionManager?.open(target)
        subscribeSession(s)
    }

    private func restart() {
        let s = scope.sessionManager?.restart(makeTarget())
        subscribeSession(s)
    }

    private func subscribeSession(_ s: RtcSession?) {
        guard let s else { return }
        s.phase.subscribe { p in Task { @MainActor in self.phase = p } }
        s.videoSize.subscribe { v in Task { @MainActor in self.videoSize = v } }
        s.firstFrame.subscribe { v in Task { @MainActor in self.firstFrame = v } }
        s.stats.subscribe { v in Task { @MainActor in self.stats = v } }
        s.deviceInfo.subscribe { v in Task { @MainActor in self.deviceInfo = v } }
        s.remoteClipboard.subscribe { text in
            // 剪贴板自动同步（对齐 Android applyRemoteClipboard）
            guard container.settings.app.clipboardSync, !text.isEmpty else { return }
            UIPasteboard.general.string = text
        }
    }

    private func makeTarget() -> StreamTarget {
        var t = StreamTarget(endpoint: scope.endpoint, deviceId: currentDevice.id,
                             deviceName: currentDevice.displayName,
                             auth: .user(token: container.session.session?.token ?? ""))
        t.settings = container.settings.stream
        t.accessMode = viewOnly ? AccessMode.viewOnly : AccessMode.full
        t.allowClipboard = container.settings.app.clipboardSync
        // 触控坐标系提示：设备逻辑分辨率（对齐 Android switchDevice 的 displayHint）
        if let d = currentDevice.info.primaryDisplay { t.displayHint = (d.width, d.height) }
        return t
    }

    // MARK: - 输入

    private func press(_ key: Int) {
        if viewOnly { toast("当前为仅观看模式"); return }
        _ = session?.input.press(key)
    }

    private func longPressKey(_ key: Int) {
        if viewOnly { toast("当前为仅观看模式"); return }
        _ = session?.input.longPress(key)
    }

    // MARK: - 面板

    @ViewBuilder
    private func sheetContent(_ p: StreamPanel) -> some View {
        switch p {
        case .tools:
            ToolGridSheet(sections: toolSections(),
                          deviceName: currentDevice.displayName,
                          transportLabel: "WebRTC 直连")
                .presentationDetents([.medium, .large])
        case .text:
            TextSendSheet(onSend: { sendText($0, $1) },
                          onSendClipboard: { sendLocalClipboard() },
                          onSendQuickText: { sendQuickText($0) },
                          onNewQuickText: { toast("请在「管理 → 快捷文本」中新建") },
                          quickTexts: scope.quickTexts)
                .presentationDetents([.medium])
        case .files:
            Group {
                if let files = session?.files.value {
                    FilePanel(client: files).environmentObject(scope)
                } else {
                    Text("文件通道未就绪").font(.subheadline).foregroundStyle(.secondary)
                        .padding()
                }
            }
            .presentationDetents([.large])
        case .quality:
            QualitySheet(settings: container.settings, onApply: { restart() })
                .presentationDetents([.medium])
        case .info:
            InfoSheet(deviceName: currentDevice.displayName,
                      deviceId: currentDevice.id,
                      server: scope.endpoint.display,
                      isGuest: isGuest,
                      videoSize: videoSize,
                      stats: stats)
                .presentationDetents([.medium])
        case .apps:
            AppsSheet(client: session?.files.value,
                      onOpenFiles: { panel = .files },
                      toast: { toast($0) },
                      allowFileTx: session?.target.allowFileTx ?? false)
                .presentationDetents([.medium])
        }
    }

    /// 对齐 Android toolSections：按会话权限动态禁用
    private func toolSections() -> [(String, [ToolItem])] {
        let control = connected && !viewOnly
        let projection = currentDevice.info.projectionOnDemand
        let allowClip = session?.target.allowClipboard ?? false

        return [
            ("设备控制", [
                ToolItem(label: "断开", icon: "rectangle.portrait.and.arrow.right") {
                    panel = nil
                    scope.sessionManager?.close(endProjection: true)
                    closePage()
                },
                ToolItem(label: "电源", icon: "power", enabled: control && !projection,
                         onLongClick: { longPressKey(Keys.power) }) { press(Keys.power) },
                ToolItem(label: container.settings.stream.powerOff ? "息屏中" : "息屏连接",
                         icon: "moon",
                         enabled: connected && !projection,
                         active: container.settings.stream.powerOff) {
                    panel = nil
                    container.settings.updateStream { $0.powerOff.toggle() }
                    toast(container.settings.stream.powerOff ? "开启息屏连接 (防窥省电)" : "恢复正常亮屏连接")
                    restart()
                },
                ToolItem(label: "音量+", icon: "speaker.wave.3", enabled: control && !projection) { press(Keys.volumeUp) },
                ToolItem(label: "音量-", icon: "speaker.wave.1", enabled: control && !projection) { press(Keys.volumeDown) },
                ToolItem(label: "通知栏", icon: "bell", enabled: control && !projection) { press(Keys.notification) },
                ToolItem(label: "截图", icon: "camera.viewfinder", enabled: connected) {
                    panel = nil
                    press(Keys.screenshot)
                },
            ]),
            ("输入", [
                ToolItem(label: "键盘输入", icon: "keyboard", enabled: control && !projection,
                         active: keyboardMode) {
                    panel = nil
                    keyboardMode.toggle()
                },
                ToolItem(label: "文本下发", icon: "text.alignleft", enabled: control && !projection) {
                    panel = .text
                },
                ToolItem(label: "发送剪贴板", icon: "doc.on.doc.fill",
                         enabled: control && allowClip && !projection) {
                    panel = nil
                    sendLocalClipboard()
                },
                ToolItem(label: "获取剪贴板", icon: "doc.on.doc",
                         enabled: control && allowClip && !projection) {
                    panel = nil
                    if session?.clipboard.getClipboard() != true { toast("剪贴板通道未就绪") }
                },
            ]),
            ("工具", [
                ToolItem(label: "文件", icon: "folder",
                         enabled: connected && (session?.target.allowFileTx ?? false) && !viewOnly) {
                    panel = .files
                },
                ToolItem(label: "安装应用", icon: "square.grid.2x2",
                         enabled: connected && (session?.target.allowFileTx ?? false) && !viewOnly) {
                    panel = .apps
                },
                ToolItem(label: "终端", icon: "terminal",
                         enabled: connected && (session?.target.allowTerminal ?? false) && !viewOnly) {
                    showTerminal = true
                },
            ]),
            ("画面与连接", [
                ToolItem(label: "切换设备", icon: "arrow.left.arrow.right",
                         enabled: canSwitchDevices) {
                    panel = nil
                    openDrawer()
                },
                ToolItem(label: "画质", icon: "slider.horizontal.3") { panel = .quality },
                ToolItem(label: audioOn ? "声音开" : "已静音",
                         icon: audioOn ? "speaker.wave.3" : "speaker.slash",
                         enabled: true, active: !audioOn) {
                    audioOn.toggle()
                    session?.setAudioEnabled(audioOn)
                    toast(audioOn ? "已开启声音" : "已静音")
                },
                ToolItem(label: "性能", icon: "speedometer",
                         enabled: true, active: container.settings.app.showStats) {
                    container.settings.updateApp { $0.showStats.toggle() }
                },
                ToolItem(label: "连接信息", icon: "info.circle") { panel = .info },
                ToolItem(label: "全屏模式", icon: "arrow.up.left.and.arrow.down.right",
                         enabled: true, active: fullscreen) {
                    panel = nil
                    fullscreen.toggle()
                },
                ToolItem(label: "重新连接", icon: "arrow.clockwise") {
                    panel = nil
                    restart()
                },
            ]),
        ]
    }

    // MARK: - 文本 / 剪贴板

    private func sendText(_ text: String, _ autoEnter: Bool) {
        if viewOnly { toast("当前为仅观看模式"); return }
        guard !text.isEmpty else { return }
        var ok: Bool
        if text.count > 200 || text.contains("\n") {
            ok = session?.clipboard.setClipboard(text, paste: true, force: true) ?? false
            if !ok { ok = session?.input.text(text) ?? false }
        } else {
            ok = session?.input.text(text) ?? false
        }
        if !ok { toast("控制通道未就绪"); return }
        if autoEnter { _ = session?.input.press(Keys.enter) }
        toast("已发送")
    }

    private func sendQuickText(_ q: QuickText) { sendText(q.content, q.autoEnter) }

    private func sendLocalClipboard() {
        if viewOnly { toast("当前为仅观看模式"); return }
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            toast("本机剪贴板为空")
            return
        }
        if session?.clipboard.setClipboard(text, force: true) == true {
            toast("已发送到云手机剪贴板")
        } else {
            toast("剪贴板通道未就绪")
        }
    }

    // MARK: - 抽屉 / 切换设备

    private func openDrawer() {
        guard canSwitchDevices else {
            toast("当前身份不支持切换设备")
            return
        }
        panel = nil
        showTerminal = false
        if keyboardMode { keyboardMode = false }
        drawerOpen = true
    }

    private func closeDrawer() { drawerOpen = false }

    private func switchDevice(_ d: Device) {
        closeDrawer()
        guard d.id != currentDevice.id else { return }
        guard d.online else {
            toast("\(d.id) 已离线")
            return
        }
        currentDevice = d
        firstFrame = false
        restart()
        toast("正在切换到 \(d.displayName)")
    }

    // MARK: - Toast

    private func toast(_ msg: String) {
        toastText = msg
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            toastText = ""
        }
    }
}
