import Foundation

/// 证书信息，对齐 Android 端 UntrustedCertificateInfo。
struct UntrustedCertificateInfo: Equatable, Identifiable {
    let endpointKey: String
    let sha256: String
    let subject: String
    let issuer: String
    let notAfter: Date
    /// true = 之前固定过但指纹变了（可能中间人 / 服务器换证书）
    let changed: Bool

    var id: String { "\(endpointKey)|\(sha256)" }
}

/// 统一错误体系，对齐 Android 端 ApiException sealed class。
/// UI 只按 case 显示 message，不接触底层错误细节。
enum ApiError: Error, LocalizedError, Equatable {
    case network(String)
    case unauthorized(String = "登录已失效，请重新登录")
    case forbidden(String = "无权限执行此操作")
    case notFound(String = "资源不存在")
    case http(code: Int, String)
    case business(code: Int, String)
    case parse(String = "服务器响应格式错误")
    case untrustedCertificate(UntrustedCertificateInfo)

    var errorDescription: String? {
        switch self {
        case .network(let m), .unauthorized(let m), .forbidden(let m),
             .notFound(let m), .http(_, let m), .business(_, let m), .parse(let m):
            return m
        case .untrustedCertificate(let info):
            return info.changed ? "服务器证书已变更" : "服务器证书不受信任"
        }
    }

    /// 归一化任意异常；证书异常优先于普通网络错误识别。
    static func from(_ error: Error) -> ApiError {
        if let apiError = error as? ApiError { return apiError }

        // 沿 underlying 链找证书异常
        var cursor: Error? = error
        while let e = cursor {
            if let certErr = e as? CertificateTrustError {
                return .untrustedCertificate(certErr.info)
            }
            cursor = (e as NSError).underlyingErrors.first
        }

        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain:
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return .network("无法解析服务器地址")
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
                return .network("无法连接服务器，请检查地址与网络")
            case NSURLErrorTimedOut:
                return .network("连接服务器超时")
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return .network("安全连接失败：TLS 握手错误")
            default:
                return .network("网络错误：\(ns.localizedDescription)")
            }
        default:
            return .network(ns.localizedDescription)
        }
    }
}

/// 内部：TOFU 证书校验失败时抛出的携带详细信息的错误
struct CertificateTrustError: Error {
    let info: UntrustedCertificateInfo
}
