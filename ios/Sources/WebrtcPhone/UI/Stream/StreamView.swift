import SwiftUI
import WebRTC
import UIKit

/// 视频渲染视图（承载 RTCMTLVideoView），页面重建时通过 SessionManager.attach 复用会话。
struct VideoRenderView: UIViewRepresentable {
    let renderer: RTCMTLVideoView

    func makeUIView(context: Context) -> RTCMTLVideoView { renderer }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}

/// 视图坐标 → 远端视频帧坐标（等比居中 fit，黑边返回 nil）。对齐 Android TouchMapper。
struct TouchMapper {
    let viewW: CGFloat, viewH: CGFloat, videoW: CGFloat, videoH: CGFloat
    private var scale: CGFloat {
        guard viewW > 0, viewH > 0, videoW > 0, videoH > 0 else { return 0 }
        return min(viewW / videoW, viewH / videoH)
    }
    private var offX: CGFloat { (viewW - videoW * scale) / 2 }
    private var offY: CGFloat { (viewH - videoH * scale) / 2 }

    func map(_ point: CGPoint, clamp: Bool) -> CGPoint? {
        guard scale > 0 else { return nil }
        var x = (point.x - offX) / scale
        var y = (point.y - offY) / scale
        let inside = x >= 0 && x <= videoW && y >= 0 && y <= videoH
        if !inside && !clamp { return nil }
        x = min(max(x, 0), videoW - 1)
        y = min(max(y, 0), videoH - 1)
        return CGPoint(x: x, y: y)
    }
}

struct StreamView: View {
    let device: Device
    @ObservedObject var scope: UserScope
    @ObservedObject var container: AppContainer

    @State private var rendererBox: RTCMTLVideoView?
    @State private var phase: ConnectionPhase = .signaling
    @State private var videoSize: (Int, Int)?
    @State private var stats = StreamStats()
    @State private var showControls = true
    @State private var showFilePanel = false
    @State private var showTerminal = false
    @State private var showKeybar = false
    @State private var errorMessage = ""
    @State private var viewOnly = false
    @State private var connectedOnce = false
    @State private var orientation: UIInterfaceOrientationMask = .all
    @Environment(\.dismiss) private var dismiss

    private var session: RtcSession? { scope.sessionManager?.session }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = rendererBox {
                VideoRenderView(renderer: renderer)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation { showControls.toggle() } }
                    .gesture(touchGesture)
            }

            // 顶部信息栏
            if showControls {
                VStack {
                    HStack {
                        Button { scope.sessionManager?.close(endProjection: true); dismiss() } label: {
                            Image(systemName: "chevron.left").font(.title2)
                        }
                        VStack(alignment: .leading) {
                            Text(device.displayName).font(.headline)
                            Text(phaseLabel).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if container.settings.app.showStats {
                            Text("\(stats.fps) fps · \(stats.latencyMs) ms")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Menu {
                            Button { restart() } label: { Label("重新连接", systemImage: "arrow.clockwise") }
                            Button {
                                viewOnly.toggle()
                                restart()
                            } label: {
                                Label(viewOnly ? "切换为完全控制" : "切换为仅观看", systemImage: "eye")
                            }
                            Button { dismiss() } label: { Label("结束投屏", systemImage: "stop.fill") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                    .padding().background(.ultraThinMaterial)
                    Spacer()
                    StreamControlBar(showFiles: $showFilePanel, showTerminal: $showTerminal,
                                     showKeybar: $showKeybar, session: session)
                        .padding(.bottom)
                        .background(.ultraThinMaterial)
                }
                .foregroundStyle(.white)
                .transition(.opacity)
            }

            // 等待/错误覆盖层
            if case .failed(let message, let retryable, _) = phase {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(message).multilineTextAlignment(.center)
                    if retryable {
                        Button("重试") { restart() }.buttonStyle(.borderedProminent)
                    }
                    Button("关闭") { dismiss() }
                }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            } else if phase != .connected {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(phaseLabel).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showFilePanel) {
            if let files = session?.files.value { FilePanel(client: files).environmentObject(scope) }
        }
        .sheet(isPresented: $showTerminal) {
            if let terminal = session?.terminal.value { TerminalPanel(channel: terminal) }
        }
        .onAppear {
            // 对齐 Android：投屏期间停掉设备大盘轮询/快照拉取，避免与视频流抢带宽
            scope.devices.setActive(false)
            connect()
        }
        .onDisappear {
            scope.devices.setActive(true)
            if let renderer = rendererBox { scope.sessionManager?.detach(renderer) }
        }
    }

    private var phaseLabel: String {
        switch phase {
        case .signaling: return "连接信令…"
        case .waitingOffer: return "等待设备应答…"
        case .waitingProjection: return "请在手机上确认投屏"
        case .negotiating: return "协商连接…"
        case .connected: return "已连接"
        case .interrupted: return "网络中断，正在恢复…"
        case .failed(let m, _, _): return m
        case .closed: return "已关闭"
        }
    }

    private func connect() {
        var target = makeTarget()
        // Metal 视图只在首次进入时创建一次；避免 SwiftUI 结构体重建时反复创建 RTCMTLVideoView
        if rendererBox == nil {
            rendererBox = RTCMTLVideoView()
            Trail.mark("sv:renderer-created")
        }
        guard let renderer = rendererBox else { return }
        Trail.mark("sv:connect dev=\(device.id)")
        scope.sessionManager?.attach(renderer)
        let s = scope.sessionManager?.open(target)
        s?.phase.subscribe { p in Task { @MainActor in self.phase = p } }
        s?.videoSize.subscribe { v in Task { @MainActor in self.videoSize = v } }
        s?.stats.subscribe { v in Task { @MainActor in self.stats = v } }
    }

    private func restart() { _ = scope.sessionManager?.restart(makeTarget()) }

    private func makeTarget() -> StreamTarget {
        var t = StreamTarget(endpoint: scope.endpoint, deviceId: device.id,
                             deviceName: device.displayName, auth: .user(token: container.session.session?.token ?? ""))
        t.settings = container.settings.stream
        t.accessMode = viewOnly ? AccessMode.viewOnly : AccessMode.full
        t.allowClipboard = container.settings.app.clipboardSync
        t.displayHint = videoSize
        return t
    }

    private var touchGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let size = videoSize, let session, let renderer = rendererBox else { return }
                let mapper = TouchMapper(viewW: renderer.bounds.width, viewH: renderer.bounds.height,
                                         videoW: CGFloat(size.0), videoH: CGFloat(size.1))
                guard let p = mapper.map(value.location, clamp: false) else { return }
                _ = session.input.touch(pointerId: 0, action: TouchAction.down,
                                        x: Int(p.x), y: Int(p.y), w: size.0, h: size.1)
            }
            .onEnded { value in
                guard let size = videoSize, let session, let renderer = rendererBox else { return }
                let mapper = TouchMapper(viewW: renderer.bounds.width, viewH: renderer.bounds.height,
                                         videoW: CGFloat(size.0), videoH: CGFloat(size.1))
                guard let p = mapper.map(value.location, clamp: true) else { return }
                _ = session.input.touch(pointerId: 0, action: TouchAction.up,
                                        x: Int(p.x), y: Int(p.y), w: size.0, h: size.1)
            }
    }
}
