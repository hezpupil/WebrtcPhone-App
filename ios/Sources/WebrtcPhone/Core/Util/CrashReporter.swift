import Foundation
import Darwin

/// 轻量崩溃采集：
/// - 未捕获 NSException：记录 name/reason/调用栈 + trail 埋点尾部
/// - 致命信号（SIGABRT 等）：以追加模式写入信号名 + 当前线程调用栈地址
///   （关键：必须 O_APPEND，不能 O_TRUNC——NSException 处理器写完报告后
///   abort() 会触发 SIGABRT，若截断会把异常详情整个覆盖掉，只剩一行 signal）
/// 「我的」页面可查看最近一次崩溃内容（自动合并 trail.log），便于远端定位。
enum CrashReporter {
    static let fileName = "crash-latest.log"

    private static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    // 信号 handler 只能做 async-signal-safe 调用：消息文本在安装时预生成
    private static var signalPath: [CChar] = []
    private static var signalMessages: [Int32: [UInt8]] = [:]

    /// 安装 handler（App 启动时调用一次）
    static func install() {
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
            case SIGTRAP: name = "SIGTRAP"
            default: continue
            }
            let text = "\n---\ntime: \(Date().timeIntervalSince1970)\ntype: signal\nname: \(name)\nstack (addresses):\n"
            signalMessages[sig] = Array(text.utf8)
        }

        NSSetUncaughtExceptionHandler { exception in
            let trail = Trail.tail() ?? "-"
            let text = """
            time: \(Date().timeIntervalSince1970)
            type: NSException
            name: \(exception.name.rawValue)
            reason: \(exception.reason ?? "-")
            stack:
            \(exception.callStackSymbols.joined(separator: "\n"))
            --- trail ---
            \(trail)

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

    /// async-signal-safe：只使用 open/write/backtrace/close
    private static func writeSignal(_ code: Int32) {
        guard !signalPath.isEmpty, let msg = signalMessages[code] else { return }
        // 追加模式：保留此前 NSException 报告 / trail 内容
        let fd = open(signalPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            msg.withUnsafeBufferPointer { buf in
                _ = write(fd, buf.baseAddress, buf.count)
            }
            // 采集当前线程调用栈地址。backtrace_symbols_fd 在信号上下文
            // 非严格 async-safe，但实践中可靠；Release 包无符号表时输出地址，
            // 配合 trail 埋点足以定位 abort 所处阶段。
            var addrs = [UnsafeMutableRawPointer?](repeating: nil, count: 128)
            let n = backtrace(&addrs, 128)
            if n > 0 {
                backtrace_symbols_fd(&addrs, Int32(n), fd)
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

    /// 读取最近崩溃内容（合并 trail 埋点）；nil 表示无崩溃记录
    static func lastReport() -> String? {
        guard let data = try? Data(contentsOf: documentsURL()), !data.isEmpty,
              let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        if let trail = Trail.tail() {
            return "--- trail (最近事件) ---\n\(trail)\n\n--- crash ---\n\(text)"
        }
        return text
    }

    static func clear() {
        try? FileManager.default.removeItem(at: documentsURL())
        Trail.clear()
    }
}
