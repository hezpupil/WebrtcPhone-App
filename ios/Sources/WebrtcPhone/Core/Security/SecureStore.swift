import Foundation
import Security

/// Keychain 安全存储。对齐 Android 端 SecureStore.kt（Keystore AES-256-GCM）。
/// 存 token、记住的密码。写失败删键；读失败清空全部并退化为重新登录。
final class SecureStore {
    static let shared = SecureStore()
    private let service = "com.webrtc_phone.android.ios.secure"

    func string(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            // 读失败：清空并退化重新登录
            clear()
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func set(_ value: String?, for key: String) -> Bool {
        guard let value else { return remove(key) }
        let data = Data(value.utf8)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let add = base.merging(attrs) { _, new in new }
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(base as CFDictionary, attrs as CFDictionary)
        }
        if status != errSecSuccess {
            // 写失败：删除该键，绝不落明文
            remove(key)
            return false
        }
        return true
    }

    @discardableResult
    func remove(_ key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
