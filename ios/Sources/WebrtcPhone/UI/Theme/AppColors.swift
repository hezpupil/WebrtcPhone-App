import SwiftUI

/// 对齐 Android 端 ui/theme/Theme.kt 的 AppColors 与色板。
enum AppColors {
    static let brand = Color(hex: "#3D7BFF")
    static let brandDark = Color(hex: "#7AA5FF")
    static let online = Color(hex: "#22C55E")
    static let offline = Color(hex: "#9CA3AF")
    static let busy = Color(hex: "#F59E0B")
    static let danger = Color(hex: "#EF4444")
    static let warning = Color(hex: "#F59E0B")

    /// 设备卡片的深色画面底（Android Color(0xFF111318)）
    static let screenBackdrop = Color(hex: "#111318")

    /// 浅色主题背景（Android background #F6F7FB）
    static let background = Color(hex: "#F6F7FB")
    /// 卡片 surface（#FFFFFF）
    static let surface = Color.white
    /// 搜索框底 surfaceContainerHigh（#EBEEF5）
    static let surfaceContainerHigh = Color(hex: "#EBEEF5")
}

/// 状态药丸（对齐 Android ui/common/Components.kt 的 Pill）
struct StatusPill: View {
    let text: String
    let color: Color
    var filled = true

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(filled ? .white : color)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(filled ? color : color.opacity(0.14), in: Capsule())
    }
}
