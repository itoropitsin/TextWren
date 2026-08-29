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
    private func baseQuery(service: String, account: String, allowInteraction: Bool) -> [CFString: Any] {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = !allowInteraction
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            // Startup reads must fail closed instead of opening SecurityAgent.
            kSecUseAuthenticationContext: authenticationContext
        ]
    }

    func readString(service: String, account: String, allowInteraction: Bool) -> KeychainReadResult {
        var query = baseQuery(service: service, account: account, allowInteraction: allowInteraction)
        query[kSecMatchLimit] = kSecMatchLimitOne
        query[kSecReturnData] = true

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
        guard let data = value.data(using: .utf8) else { return false }

        let query = baseQuery(service: service, account: account, allowInteraction: allowInteraction)
        let attributes: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = query
        addQuery[kSecValueData] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    func delete(service: String, account: String, allowInteraction: Bool) -> Bool {
        let query = baseQuery(service: service, account: account, allowInteraction: allowInteraction)
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
        let key = KeychainCacheKey(service: service, account: account)
        lock.lock()
        if let cached = cache[key] {
            // An explicit Retry may re-check a previous miss or failure. A
            // successful value is safe to reuse and never needs a prompt.
            let shouldRetry = allowInteraction && {
                if case .value = cached { return false }
                return true
            }()
            if !shouldRetry {
                lock.unlock()
                return cached
            }
        }

        // Keep the lock through the first read so concurrent startup callers
        // cannot ask SecurityAgent twice for one account.
        let result = base.readString(service: service, account: account, allowInteraction: allowInteraction)
        cache[key] = result
        lock.unlock()
        return result
    }

    func saveString(_ value: String, service: String, account: String, allowInteraction: Bool) -> Bool {
        let saved = base.saveString(value, service: service, account: account, allowInteraction: allowInteraction)
        if saved { invalidate(service: service, account: account) }
        return saved
    }

    @discardableResult
    func delete(service: String, account: String, allowInteraction: Bool) -> Bool {
        let deleted = base.delete(service: service, account: account, allowInteraction: allowInteraction)
        if deleted { invalidate(service: service, account: account) }
        return deleted
    }

    private func invalidate(service: String, account: String) {
        lock.lock()
        cache = cache.filter { key, _ in key.service != service || key.account != account }
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

    @discardableResult
    static func saveString(_ value: String, service: String, account: String) -> Bool {
        client.saveString(value, service: service, account: account, allowInteraction: true)
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        client.delete(service: service, account: account, allowInteraction: true)
    }
}
