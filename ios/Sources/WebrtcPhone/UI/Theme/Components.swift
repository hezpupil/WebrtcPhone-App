import SwiftUI

/// 对齐 Android 端 ui/common/Components.kt 的通用组件。

/// 分组卡片容器（标题 labelLarge 灰色 + 大圆角卡片）
struct SectionCard<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
            VStack(spacing: 0) { content }
                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 20))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(.black.opacity(0.06), lineWidth: 0.5))
        }
    }
}

/// 「图标 + 标题 + 副标题 + 右箭头」行式入口（对齐 Android SettingRow）
struct EntryRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    var destructive = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(destructive ? AppColors.danger : .primary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing?.padding(.trailing, 4)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

/// 大数字统计卡（对齐 Android StatCard）
struct StatCard: View {
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black.opacity(0.06), lineWidth: 0.5))
    }
}

/// 可点击小统计卡（对齐 Android StatMiniCard，选中高亮）
struct StatMiniCard: View {
    let value: String
    let label: String
    let color: Color
    var selected = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            VStack(spacing: 2) {
                Text(value).font(.system(size: 16, weight: .bold)).foregroundStyle(color)
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(selected ? color.opacity(0.16) : AppColors.surface,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? color : Color.black.opacity(0.08),
                            lineWidth: selected ? 1.5 : 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

/// 空状态（72dp 圆形图标底 + 标题 + 说明 + 可选按钮）
struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(AppColors.brand)
                .frame(width: 72, height: 72)
                .background(AppColors.brand.opacity(0.10), in: Circle())
            Text(title).font(.system(size: 15, weight: .semibold))
            if let message {
                Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent).tint(AppColors.brand)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// 圆形搜索框（对齐 Android SearchBox）
struct RoundedSearchField: View {
    @Binding var text: String
    var placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(AppColors.surfaceContainerHigh, in: Capsule())
    }
}

/// 横滚筛选 chip（对齐 Android FilterChip 圆角 50）
struct FilterChip: View {
    let text: String
    var color: Color = AppColors.brand
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 13).padding(.vertical, 7)
                .background(selected ? color : AppColors.surfaceContainerHigh, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// 首字母头像（对齐 Android UserCard 头像）
struct InitialAvatar: View {
    let username: String
    var isAdmin: Bool
    var size: CGFloat = 38
    var showOnlineDot: Bool = false
    var online: Bool = false

    private var letter: String {
        String(username.first.map { String($0).uppercased() } ?? "?")
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Text(letter)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(isAdmin ? AppColors.brand : .primary)
                .frame(width: size, height: size)
                .background(isAdmin ? AppColors.brand.opacity(0.15) : AppColors.surfaceContainerHigh,
                            in: Circle())
            if showOnlineDot {
                Circle()
                    .fill(online ? AppColors.online : AppColors.offline)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
        }
    }
}

/// 文本输入弹窗（对齐 Android TextInputDialog）
struct TextInputDialog: View {
    let title: String
    let label: String
    var initial: String = ""
    var maxLength: Int = 100
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(title: String, label: String, initial: String = "", maxLength: Int = 100,
         onConfirm: @escaping (String) -> Void) {
        self.title = title
        self.label = label
        self.initial = initial
        self.maxLength = maxLength
        self.onConfirm = onConfirm
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField(label, text: $text)
                    .onChange(of: text) { v in
                        if v.count > maxLength { text = String(v.prefix(maxLength)) }
                    }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定") {
                        dismiss()
                        onConfirm(text.trimmingCharacters(in: .whitespaces))
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
