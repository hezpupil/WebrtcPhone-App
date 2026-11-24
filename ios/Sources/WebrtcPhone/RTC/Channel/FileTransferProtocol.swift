import Foundation
import CryptoKit

enum RemoteFile: Decodable {
    case file(name: String, path: String, isDir: Bool, size: Int64, modTime: Int64)

    var name: String { if case .file(let n, _, _, _, _) = self { return n }; return "" }
    var path: String { if case .file(_, let p, _, _, _) = self { return p }; return "" }
    var isDir: Bool { if case .file(_, _, let d, _, _) = self { return d }; return false }
    var size: Int64 { if case .file(_, _, _, let s, _) = self { return s }; return 0 }
    /// 秒 → 毫秒
    var modTimeMillis: Int64 { if case .file(_, _, _, _, let t) = self { return t * 1000 }; return 0 }
}

/// file-channel 协议编码与响应解析。对齐 Android 端 FileTransferClient.kt。
enum FileTransferProtocol {
    static let chunkSize = 16 * 1024
    static let flowControlBytes = 1024 * 1024
    static let replyTimeoutMs: Int64 = 15_000
    static let stallTimeoutMs: Int64 = 30_000

    static func list(_ path: String) -> String { json(["type": "list", "path": path]) }
    static func mkdir(_ path: String) -> String { json(["type": "mkdir", "path": path]) }
    static func delete(_ path: String) -> String { json(["type": "delete", "path": path]) }
    static func installApk(_ path: String, requestId: String) -> String {
        json(["type": "install_apk", "path": path, "request_id": requestId])
    }
    static func uploadStart(path: String, size: Int64, sha256: String, installOnFinish: Bool) -> String {
        json(["type": "upload_start", "path": path, "size": size,
              "sha256": sha256, "install_on_finish": installOnFinish])
    }
    static func downloadStart(path: String, requestId: String) -> String {
        json(["type": "download_start", "path": path, "request_id": requestId])
    }
    static func uploadCancel(_ path: String) -> String { json(["type": "upload_cancel", "path": path]) }
    static func downloadCancel(_ path: String) -> String { json(["type": "download_cancel", "path": path]) }

    static func replyType(for request: String) -> String? {
        let type = (try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])?["type"] as? String ?? ""
        switch type {
        case "list": return "list_reply"
        case "mkdir": return "mkdir_reply"
        case "delete": return "delete_reply"
        case "install_apk": return "install_status"
        case "upload_start": return "upload_reply"
        case "download_start": return "download_reply"
        default: return nil
        }
    }

    static func parseList(_ text: String) -> ([RemoteFile], String?)? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        return parseList(o)
    }

    static func parseList(_ o: [String: Any]) -> ([RemoteFile], String?)? {
        guard let success = o["success"] as? Bool else { return nil }
        if !success {
            let err = o["error"] as? String ?? "读取目录失败"
            return ([], err)
        }
        var files: [RemoteFile] = []
        if let arr = o["files"] as? [Any] {
            for raw in arr {
                guard let f = raw as? [String: Any] else { continue }
                let size = (f["size"] as? NSNumber)?.int64Value ?? 0
                let mod = (f["mod_time"] as? NSNumber)?.int64Value ?? 0
                files.append(.file(name: f["name"] as? String ?? "",
                                   path: f["path"] as? String ?? "",
                                   isDir: f["is_dir"] as? Bool ?? false,
                                   size: size, modTime: mod))
            }
        }
        return (files, nil)
    }

    /// 64KB 流式计算文件 SHA-256（小写 hex）
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = CryptoKit.SHA256()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func json(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
