import SwiftUI

/// WebADB 终端面板（adb-channel PTY 裸字节）
struct TerminalPanel: View {
    let channel: TerminalChannel
    @State private var lines: [String] = []
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(lines.indices, id: \.self) { i in
                                Text(lines[i]).font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: lines.count) { _ in
                        if let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                Divider()
                HStack {
                    TextField("输入命令", text: $input)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .focused($focused)
                        .onSubmit { send() }
                    Button("发送") { send() }
                }
                .padding(10)
                .background(.thinMaterial)
            }
            .navigationTitle("终端")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button { channel.clear(); lines.removeAll() } label: { Image(systemName: "trash") }
                        Button { focused = true } label: { Image(systemName: "keyboard") }
                    }
                }
            }
            .onAppear {
                _ = channel.start(rows: 24, cols: 80)
                channel.observe { data in
                    let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                    let result = channel.append(data)
                    DispatchQueue.main.async {
                        if result.reset { lines.removeAll() }
                        let combined = (lines.last ?? "") + text
                        if !lines.isEmpty { lines[lines.count - 1] = combined }
                        else { lines = text.split(separator: "\n").map(String.init) }
                        // 处理多行
                        if combined.contains("\n") {
                            let parts = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                            if lines.count >= 1 { lines.removeLast() }
                            lines.append(contentsOf: parts)
                        }
                    }
                }
                focused = true
            }
        }
        .presentationDetents([.large])
    }

    private func send() {
        guard !input.isEmpty else { return }
        _ = channel.write((input + "\n").data(using: .utf8) ?? Data())
        input = ""
    }
}
