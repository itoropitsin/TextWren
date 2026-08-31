import Foundation
import LocalAuthentication
import Security

enum KeychainReadResult: Equatable {
    case value(String)
    case missing
    case interactionRequired
    case failure(Int32)
}

protocol KeychainClient: AnyObject {
    func readString(service: String, account: String, allowInteraction: Bool) -> KeychainReadResult
    func saveString(_ value: String, service: String, account: String, allowInteraction: Bool) -> Bool
    func delete(service: String, account: String, allowInteraction: Bool) -> Bool
}

private struct KeychainCacheKey: Hashable {
    let service: String
    let account: String
}

final class SystemKeychainClient: KeychainClient {
    static func shouldAddAfterUpdate(_ status: OSStatus) -> Bool {
        status == errSecItemNotFound
    }

    private func authenticationContext(allowInteraction: Bool) -> LAContext {
        let context = LAContext()
        // Startup reads must fail closed instead of presenting a Keychain
        // dialog.  Settings retries opt in to interaction explicitly.
        context.interactionNotAllowed = !allowInteraction
        return context
    }

    func readString(service: String, account: String, allowInteraction: Bool) -> KeychainReadResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
            kSecUseAuthenticationContext: authenticationContext(allowInteraction: allowInteraction)
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                return .failure(errSecDecode)
            }
            return .value(value)
        case errSecItemNotFound:
            return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .interactionRequired
        default:
            return .failure(status)
        }
    }

    func saveString(_ value: String, service: String, account: String, allowInteraction: Bool) -> Bool {
        guard let data = value.data(using: .utf8) else {
            return false
        }

        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseAuthenticationContext: authenticationContext(allowInteraction: allowInteraction)
        ]

        let attributes: [CFString: Any] = [
            kSecValueData: data
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }

        // Only create a new item when the update proved that no item exists.
        // Other failures (for example an authentication or access error) must
        // not be turned into an unexpected duplicate-add attempt.
        guard Self.shouldAddAfterUpdate(status) else {
            return false
        }

        var addQuery = query
        addQuery[kSecValueData] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    func delete(service: String, account: String, allowInteraction: Bool) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecUseAuthenticationContext: authenticationContext(allowInteraction: allowInteraction)
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

final class CachingKeychainClient: KeychainClient {
    private let base: KeychainClient
    private var cache: [KeychainCacheKey: KeychainReadResult] = [:]
    private let lock = NSLock()

    init(base: KeychainClient) {
        self.base = base
    }

    func readString(service: String, account: String, allowInteraction: Bool) -> KeychainReadResult {
        let cacheKey = KeychainCacheKey(service: service, account: account)
        lock.lock()
        if let cached = cache[cacheKey] {
            // A normal startup read must never turn a cached failure into a
            // repeated prompt. An explicit Settings retry is different: it is
            // the one place where the user has asked us to try an interaction
            // again after allowing the Keychain item.
            let shouldRetryInteraction = allowInteraction && {
                if case .interactionRequired = cached { return true }
                if case .failure = cached { return true }
                return false
            }()
            if !shouldRetryInteraction {
                lock.unlock()
                return cached
            }
        }
        // Keep the lock while performing the first read.  This avoids two
        // simultaneous callers both missing the cache and asking Keychain for
        // the same account.
        let result = base.readString(service: service, account: account, allowInteraction: allowInteraction)
        cache[cacheKey] = result
        lock.unlock()
        return result
    }

    func saveString(_ value: String, service: String, account: String, allowInteraction: Bool) -> Bool {
        let saved = base.saveString(value, service: service, account: account, allowInteraction: allowInteraction)
        if saved {
            invalidate(service: service, account: account)
        }
        return saved
    }

    @discardableResult
    func delete(service: String, account: String, allowInteraction: Bool) -> Bool {
        let deleted = base.delete(service: service, account: account, allowInteraction: allowInteraction)
        if deleted {
            invalidate(service: service, account: account)
        }
        return deleted
    }

    private func invalidate(service: String, account: String) {
        lock.lock()
        cache = cache.filter { key, _ in
            key.service != service || key.account != account
        }
        lock.unlock()
    }
}

enum KeychainStore {
    static let client: KeychainClient = CachingKeychainClient(base: SystemKeychainClient())

    static func loadString(service: String, account: String) -> String? {
        if case .value(let value) = client.readString(service: service, account: account, allowInteraction: false) {
            return value
        }
        return nil
    }

    static func saveString(_ value: String, service: String, account: String) -> Bool {
        client.saveString(value, service: service, account: account, allowInteraction: true)
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        client.delete(service: service, account: account, allowInteraction: true)
    }
}
