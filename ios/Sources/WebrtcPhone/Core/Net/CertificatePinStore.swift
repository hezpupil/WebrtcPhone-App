import Foundation
import Security
import CryptoKit

/// TOFU 证书指纹固定存储。对齐 Android 端 CertificatePinStore.kt。
/// 值格式：`sha256|pinnedAt(ms)|subject`，键 `pin:<host:port>`。
/// SHA-256 针对叶子证书 DER 整体，大写冒号分隔。
final class CertificatePinStore {
    private let defaults: UserDefaults
    private let keyPrefix = "pin:"

    init(defaults: UserDefaults = UserDefaults.standard) {
        self.defaults = defaults
    }

    struct PinnedCertificate: Identifiable {
        var id: String { endpointKey }
        let endpointKey: String
        let sha256: String
        let subject: String
        let pinnedAt: Date
    }

    func fingerprint(for endpointKey: String) -> String? {
        guard let raw = defaults.string(forKey: keyPrefix + endpointKey) else { return nil }
        return raw.split(separator: "|", maxSplits: 1).first.map(String.init)
    }

    func pin(endpointKey: String, sha256: String, subject: String) {
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        defaults.set("\(sha256)|\(ms)|\(subject)", forKey: keyPrefix + endpointKey)
    }

    func remove(endpointKey: String) {
        defaults.removeObject(forKey: keyPrefix + endpointKey)
    }

    func load() -> [PinnedCertificate] {
        defaults.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix(keyPrefix), let raw = value as? String else { return nil }
            let parts = raw.split(separator: "|", maxSplits: 2).map(String.init)
            let sha = parts.first ?? ""
            let ms = Int64(parts.dropFirst().first ?? "") ?? 0
            let subject = parts.count > 2 ? parts[2] : ""
            return PinnedCertificate(
                endpointKey: String(key.dropFirst(keyPrefix.count)),
                sha256: sha,
                subject: subject,
                pinnedAt: Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            )
        }
        .sorted { $0.endpointKey < $1.endpointKey }
    }

    /// 计算 X509 证书 DER 的 SHA-256，大写冒号分隔。
    static func sha256(of certificate: SecCertificate) -> String? {
        let der = SecCertificateCopyData(certificate) as Data
        let digest = Array(CryptoKit.SHA256.hash(data: der))
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    static func subject(of certificate: SecCertificate) -> String {
        SecCertificateCopySubjectSummary(certificate) as String? ?? ""
    }
}
