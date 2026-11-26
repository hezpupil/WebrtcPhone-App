import SwiftUI
import UIKit

// MARK: - 触摸映射

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

// MARK: - 触摸透传视图

/**
 * 画面触控 → 远端多点触控。对齐 Android TouchForwarder：
 * - 多指按 pointerId 透传（手势缩放、多指操作）；
 * - 按下点落在黑边则该指丢弃，移动/抬起时钳制到边缘，保证远端手势完整；
 * - 触控坐标系 = 设备逻辑分辨率（deviceInfo.primaryDisplay），而非编码后的视频帧
 *   尺寸（max_size 会缩小帧）；画面方向与设备默认方向不一致时宽高互换，
 *   agent 按此尺寸校验并换算，尺寸不符的事件会被丢弃。
 */
final class TouchForwardView: UIView {
    var session: RtcSession?
    var videoSize: (Int, Int)?
    /// 设备逻辑分辨率（已按画面方向做过宽高互换），nil 时回退 displayHint/videoSize
    var displaySize: (Int, Int)?
    var viewOnly = false
    var hapticsEnabled = true

    private var pointerIds: [ObjectIdentifier: Int] = [:]
    private var nextPointerId = 0
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// 对齐 Android TouchForwarder.targetSize
    private func targetSize() -> (Int, Int)? {
        guard let video = videoSize else { return nil }
        let disp: (Int, Int)? = displaySize ?? session?.target.displayHint
        guard let d = disp else { return video }
        let rotated = (video.0 > video.1) != (d.0 > d.1)
        return rotated ? (d.1, d.0) : d
    }

    private func send(_ touch: UITouch, action: Int, clamp: Bool) {
        guard let session, let size = targetSize(), !viewOnly else { return }
        let mapper = TouchMapper(viewW: bounds.width, viewH: bounds.height,
                                 videoW: CGFloat(size.0), videoH: CGFloat(size.1))
        // 黑边按下（clamp=false 且越界）：丢弃该指，对齐 Android（不注册 activePointers）
        guard let p = mapper.map(touch.location(in: self), clamp: clamp) else {
            if action == TouchAction.down { pointerIds.removeValue(forKey: ObjectIdentifier(touch)) }
            return
        }
        guard let id = pointerIds[ObjectIdentifier(touch)] else { return }
        _ = session.input.touch(pointerId: id, action: action,
                                x: Int(p.x), y: Int(p.y), w: size.0, h: size.1)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            pointerIds[ObjectIdentifier(t)] = nextPointerId
            nextPointerId += 1
            if hapticsEnabled && pointerIds.count == 1 { haptic.impactOccurred() }
            // 黑边按下：Android 直接丢弃该指（不发送），移动/抬起自然也不会有事件
            send(t, action: TouchAction.down, clamp: false)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { send(t, action: TouchAction.move, clamp: true) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where pointerIds.removeValue(forKey: ObjectIdentifier(t)) != nil {
            send(t, action: TouchAction.up, clamp: true)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches where pointerIds.removeValue(forKey: ObjectIdentifier(t)) != nil {
            send(t, action: TouchAction.cancel, clamp: true)
        }
    }
}

/// SwiftUI 包装：透明覆盖在渲染视图上承接全部触摸
struct TouchLayer: UIViewRepresentable {
    let session: RtcSession?
    let videoSize: (Int, Int)?
    let displaySize: (Int, Int)?
    let viewOnly: Bool
    let haptics: Bool

    func makeUIView(context: Context) -> TouchForwardView { TouchForwardView() }

    func updateUIView(_ v: TouchForwardView, context: Context) {
        v.session = session
        v.videoSize = videoSize
        v.displaySize = displaySize
        v.viewOnly = viewOnly
        v.hapticsEnabled = haptics
    }
}

// MARK: - 虚拟导航键（对齐 Android NavKeys）

/// 虚拟导航键：返回 / 主页 / 多任务（长按返回 = 菜单）
struct NavKeysBar: View {
    let onKey: (Int) -> Void
    let onLongKey: (Int) -> Void

    private let items: [(icon: String, label: String, key: Int, size: CGFloat)] = [
        ("arrow.left", "返回", Keys.back, 20),
        ("circle.fill", "主页", Keys.home, 16),
        ("line.3.horizontal", "多任务", Keys.appSwitch, 20),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                let it = items[i]
                Image(systemName: it.icon)
                    .font(.system(size: it.size))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { onKey(it.key) }
                    .onLongPressGesture(minimumDuration: 0.5) {
                        onLongKey(it.key == Keys.back ? Keys.menu : it.key)
                    }
                    .accessibilityLabel(it.label)
            }
        }
        .frame(height: 44)
        .background(Color.black)
    }
}

// MARK: - 左侧边缘把手（对齐 Android DrawerHandle）

/// 常驻左侧把手：点击打开"切换设备"侧边栏。只点击不滑动，避免与云手机边缘返回手势冲突。
struct DrawerHandle: View {
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 64)
                .background(Color(hex: "1F2633").opacity(0.8),
                            in: UnevenRoundedRectangle(topTrailingRadius: 12, bottomTrailingRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 可拖动悬浮球（对齐 Android FloatingBall）

/// 点击展开工具面板，长按打开设备侧边栏，拖动后吸附屏幕左右边缘
struct FloatingBall: View {
    let onClick: () -> Void
    let onLongClick: (() -> Void)?

    @State private var position: CGPoint = .zero
    @State private var initialized = false
    @State private var dragBase: CGPoint = .zero
    @State private var dragging = false
    @State private var dragMoved: CGFloat = 0
    @State private var longPressFired = false
    @State private var longPressTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geo in
            let ball: CGFloat = 48
            let maxX = geo.size.width - ball
            let maxY = geo.size.height - ball

            Image(systemName: "square.grid.2x2")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: ball, height: ball)
                .background(Color(hex: "1F2633").opacity(0.8), in: Circle())
                .shadow(radius: 6)
                .position(initialized ? position : CGPoint(x: maxX, y: maxY * 0.35))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            if !dragging {
                                dragging = true
                                dragMoved = 0
                                longPressFired = false
                                dragBase = initialized ? position : CGPoint(x: maxX, y: maxY * 0.35)
                                initialized = true
                                longPressTask = Task {
                                    try? await Task.sleep(nanoseconds: 550_000_000)
                                    guard !Task.isCancelled else { return }
                                    if dragging && dragMoved < 10 {
                                        longPressFired = true
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        onLongClick?()
                                    }
                                }
                            }
                            dragMoved = abs(v.translation.width) + abs(v.translation.height)
                            if dragMoved > 10 { longPressTask?.cancel() }
                            position = CGPoint(
                                x: min(max(dragBase.x + v.translation.width, ball / 2), maxX + ball / 2),
                                y: min(max(dragBase.y + v.translation.height, ball / 2), maxY + ball / 2))
                        }
                        .onEnded { _ in
                            longPressTask?.cancel()
                            let wasTap = dragging && dragMoved < 8 && !longPressFired
                            // 吸附左右边缘（球心：左半屏 → ball/2，右半屏 → maxX + ball/2）
                            let edgeX: CGFloat = (position.x < geo.size.width / 2) ? ball / 2 : maxX + ball / 2
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                position = CGPoint(x: edgeX, y: position.y)
                            }
                            dragging = false
                            if wasTap { onClick() }
                        }
                )
        }
    }
}

// MARK: - 键盘输入条（对齐 Android KeyboardBar）

/// 键盘高度监听：主画面禁用 SwiftUI 自动避让（画面保持不动），输入条手动上移
final class KeyboardHeightObserver: ObservableObject {
    @Published var height: CGFloat = 0
    private var bag: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        bag.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification,
                                      object: nil, queue: .main) { [weak self] n in
            self?.height = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect)?.height ?? 0
        })
        bag.append(center.addObserver(forName: UIResponder.keyboardWillHideNotification,
                                      object: nil, queue: .main) { [weak self] _ in
            self?.height = 0
        })
    }

    deinit { bag.forEach { NotificationCenter.default.removeObserver($0) } }
}

/// 底部键盘输入条：文字走 inject_text 下发，回车键发送 ENTER
struct KeyboardBar: View {
    let session: RtcSession?
    let onDone: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("输入文字下发到云手机", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(8)
                .background(Color(hex: "1F2633").opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                .focused($focused)
                .onSubmit { send() }
            Button { _ = session?.input.press(Keys.enter) } label: {
                Image(systemName: "keyboard.return").font(.title3).foregroundStyle(.white)
            }
            Button { onDone() } label: {
                Image(systemName: "checkmark").font(.title3).foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .onAppear { focused = true }
    }

    private func send() {
        guard !text.isEmpty else { return }
        _ = session?.input.text(text)
        text = ""
    }
}

// MARK: - 性能浮层（对齐 Android StatsHud）

/// 角落性能浮层：延迟 / 帧率 / 码率 / 丢包 / 网络 / 分辨率
struct StatsHud: View {
    let stats: StreamStats

    private var bitrate: String {
        let bps = stats.bitrateBps
        if bps <= 0 { return "--" }
        if bps >= 1_000_000 { return String(format: "%.1fMbps", Double(bps) / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0fKbps", Double(bps) / 1_000) }
        return "\(bps)bps"
    }

    var body: some View {
        Text(hudText)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }

    private var hudText: String {
        var s = "\(stats.latencyMs > 0 ? "\(stats.latencyMs)ms" : "--")  \(stats.fps)fps  \(bitrate)"
        if stats.packetLossPct >= 0.1 { s += String(format: "  丢包%.1f%%", stats.packetLossPct) }
        if !stats.networkLabel.isEmpty { s += "\n\(stats.networkLabel)" }
        if stats.width > 0 { s += "  \(stats.width)×\(stats.height)" }
        return s
    }
}

// MARK: - 顶部提示条（对齐 Android Banner）

struct StreamBanner: View {
    let text: String
    let warning: Bool

    var body: some View {
        HStack(spacing: 8) {
            if warning { ProgressView().tint(.white).scaleEffect(0.6).frame(width: 12, height: 12) }
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background((warning ? Color(hex: "B8860B") : Color.gray).opacity(0.9),
                    in: RoundedRectangle(cornerRadius: 6))
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { min(max(self, range.lowerBound), range.upperBound) }
}
