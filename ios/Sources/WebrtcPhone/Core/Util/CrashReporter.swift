import Foundation
import Darwin

/// 轻量崩溃采集：捕获未处理 NSException 与致命信号，写入沙盒 Documents。
/// 「我的」页面可查看最近一次崩溃内容，便于远端定位。
enum CrashReporter {
    static let fileName = "crash-latest.log"

    private static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    // 信号 handler 只能做 async-signal-safe 调用：路径与消息文本在安装时预生成
    private static var signalPath: [CChar] = []
    private static var signalMessages: [Int32: [UInt8]] = [:]

    /// 安装 handler（App 启动时调用一次）
    static func install() {
        // 预生成信号消息与文件路径
        let path = documentsURL().path
        signalPath = path.cString(using: .utf8) ?? []
        for sig in signals {
            let name: String
            switch sig {
            case SIGABRT: name = "SIGABRT"
            case SIGSEGV: name = "SIGSEGV"
            case SIGBUS: name = "SIGBUS"
            case SIGILL: name = "SIGILL"
            case SIGFPE: name = "SIGFPE"
            case SIGTRAP: name = "SIGTRAP (可能为 Swift 运行时陷阱：强制解包/数组越界/溢出)"
            default: continue
            }
            let text = "time: \(Date().timeIntervalSince1970)\ntype: signal\nname: \(name)\n"
            signalMessages[sig] = Array(text.utf8)
        }

        NSSetUncaughtExceptionHandler { exception in
            let text = """
            time: \(Date().timeIntervalSince1970)
            type: NSException
            name: \(exception.name.rawValue)
            reason: \(exception.reason ?? "-")
            stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            try? text.data(using: .utf8)?.write(to: CrashReporter.documentsURL(), options: .atomic)
        }

        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_sigaction = { code, _, _ in
                CrashReporter.writeSignal(code)
            }
            action.sa_flags = Int32(SA_SIGINFO)
            sigaction(sig, &action, nil)
        }
    }

    /// async-signal-safe：只使用 open/write/close
    private static func writeSignal(_ code: Int32) {
        guard !signalPath.isEmpty, let msg = signalMessages[code] else { return }
        let fd = open(signalPath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            msg.withUnsafeBufferPointer { buf in
                _ = write(fd, buf.baseAddress, buf.count)
            }
            close(fd)
        }
        signal(code, SIG_DFL)
        raise(code)
    }

    static func documentsURL() -> URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent(fileName)
    }

    /// 读取最近崩溃内容；nil 表示无崩溃记录
    static func lastReport() -> String? {
        guard let data = try? Data(contentsOf: documentsURL()), !data.isEmpty,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    static func clear() { try? FileManager.default.removeItem(at: documentsURL()) }
}
