import SwiftUI
import UniformTypeIdentifiers

/// 设备文件管理面板（file-channel）
struct FilePanel: View {
    @ObservedObject var client: FileTransferClient
    @EnvironmentObject var scope: UserScope
    @State private var path = "/sdcard"
    @State private var files: [RemoteFile] = []
    @State private var error: String?
    @State private var showUpload = false

    var body: some View {
        NavigationStack {
            List {
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                ForEach(files, id: \.path) { file in
                    HStack {
                        Image(systemName: file.isDir ? "folder" : "doc")
                            .foregroundStyle(file.isDir ? .yellow : .blue)
                        VStack(alignment: .leading) {
                            Text(file.name).font(.subheadline)
                            if !file.isDir { Text("\(file.size) 字节").font(.caption2).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        if !file.isDir && file.name.lowercased().hasSuffix(".apk") {
                            Button("安装") {
                                Task { _ = client.installApk(file.path) }
                            }.buttonStyle(.bordered)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if file.isDir {
                            path = file.path
                            Task { await load() }
                        }
                    }
                }
                if !client.transfers.isEmpty {
                    Section("传输") {
                        ForEach(client.transfers) { t in
                            VStack(alignment: .leading) {
                                Text(t.name).font(.caption)
                                ProgressView(value: t.progress)
                                Text(t.state.rawValue + (t.error.map { " · \($0)" } ?? ""))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(path)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("上级") { path = (path as NSString).deletingLastPathComponent; Task { await load() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        Button { showUpload = true } label: { Image(systemName: "square.and.arrow.up") }
                    }
                }
            }
            .fileImporter(isPresented: $showUpload, allowedContentTypes: [.item]) { result in
                if case .success(let url) = result {
                    Task {
                        let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
                        try? await client.upload(src: url, name: url.lastPathComponent,
                                                 remotePath: path + "/" + url.lastPathComponent,
                                                 size: size?.int64Value ?? 0)
                        await load()
                    }
                }
            }
            .onAppear { Task { await load() } }
        }
        // detents 由宿主 sheetContent 统一声明（.large），此处不再重复
    }

    private func load() async {
        do { files = try await client.list(path); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
