import Foundation
import Security

/// Canonicalizes only origins that CloudConfiguration is permitted to provide.
/// The canonical value is used both as the Keychain account and as an integrity
/// field in the encoded record, so records cannot be used across origins.
enum CloudStoreOrigin {
    static func canonical(_ origin: String) -> String? {
        guard let components = URLComponents(string: origin),
              let rawScheme = components.scheme?.lowercased(),
              let rawHost = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.port.map({ (1...65_535).contains($0) }) ?? true
        else { return nil }

        let permitsHTTP = ["127.0.0.1", "localhost", "::1", "[::1]"].contains(rawHost)
        guard rawScheme == "https" || (rawScheme == "http" && permitsHTTP) else { return nil }

        var normalized = URLComponents()
        normalized.scheme = rawScheme
        normalized.host = rawHost
        let defaultPort = rawScheme == "https" ? 443 : 80
        normalized.port = components.port == defaultPort ? nil : components.port
        return normalized.url?.absoluteString
    }
}

@MainActor
enum KeychainCredentialReadResult {
    case value(Data)
    case itemNotFound
    case failure(OSStatus)
}

/// This narrow boundary keeps Security.framework out of unit tests. The
/// production implementation is the only type that calls SecItem APIs.
@MainActor
protocol KeychainCredentialBacking: AnyObject {
    func read(service: String, account: String) -> KeychainCredentialReadResult
    func add(data: Data, service: String, account: String) -> OSStatus
    func update(data: Data, service: String, account: String) -> OSStatus
}

@MainActor
final class SecurityKeychainCredentialBacking: KeychainCredentialBacking {
    // Local unsigned development builds have no entitlement for the data
    // protection keychain. Select the login keychain explicitly at build time,
    // never as a runtime fallback after a storage failure.
    #if DEBUG
    private let usesDataProtectionKeychain = false
    #else
    private let usesDataProtectionKeychain = true
    #endif
    func read(service: String, account: String) -> KeychainCredentialReadResult {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain: usesDataProtectionKeychain,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return .itemNotFound }
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = item as? Data else { return .failure(errSecDecode) }
        return .value(data)
    }

    func add(data: Data, service: String, account: String) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain: usesDataProtectionKeychain,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: data
        ]
        return SecItemAdd(query as CFDictionary, nil)
    }

    func update(data: Data, service: String, account: String) -> OSStatus {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain: usesDataProtectionKeychain,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any
        ]
        let attributes: [CFString: Any] = [kSecValueData: data]
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }
}

private enum StoreRecordDecodingError: Error {
    case invalid
}

private struct CredentialStoreCodingKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct StoredInstallationCredential: Codable {
    static let version = 1

    let version: Int
    let origin: String
    let installationID: UUID
    let accessToken: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case version
        case origin
        case installationID
        case accessToken
    }

    init(credential: InstallationCredential, origin: String) {
        version = Self.version
        self.origin = origin
        installationID = credential.installationID
        accessToken = credential.accessToken
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(keyedBy: CredentialStoreCodingKey.self)
        guard Set(rawContainer.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw StoreRecordDecodingError.invalid
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.version else { throw StoreRecordDecodingError.invalid }
        self.version = version
        origin = try container.decode(String.self, forKey: .origin)
        installationID = try container.decode(UUID.self, forKey: .installationID)
        accessToken = try container.decode(String.self, forKey: .accessToken)
    }

    var credential: InstallationCredential {
        InstallationCredential(installationID: installationID, accessToken: accessToken)
    }
}

/// Stores the anonymous installation credential in a non-synchronizing,
/// Keychain generic-password item (login keychain for unsigned Debug builds). No fallback persistence is
/// available: every validation or Security.framework failure fails closed.
@MainActor
final class KeychainInstallationCredentialStore: InstallationCredentialStoring {
    private let backing: any KeychainCredentialBacking
    private let service = "com.saydrop.installation-credential.v1"

    init() {
        backing = SecurityKeychainCredentialBacking()
    }

    init(backing: any KeychainCredentialBacking) {
        self.backing = backing
    }

    func read(origin: String) throws -> InstallationCredential? {
        guard let origin = CloudStoreOrigin.canonical(origin) else { throw CloudClientError.credentialStorage }

        switch backing.read(service: service, account: origin) {
        case .itemNotFound:
            return nil
        case .failure:
            throw CloudClientError.credentialStorage
        case .value(let data):
            do {
                let record = try JSONDecoder().decode(StoredInstallationCredential.self, from: data)
                let credential = record.credential
                guard record.origin == origin, credential.isValid else { throw StoreRecordDecodingError.invalid }
                return credential
            } catch {
                throw CloudClientError.credentialStorage
            }
        }
    }

    func save(_ credential: InstallationCredential, origin: String) throws {
        guard let origin = CloudStoreOrigin.canonical(origin), credential.isValid else {
            throw CloudClientError.credentialStorage
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(StoredInstallationCredential(credential: credential, origin: origin))
        } catch {
            throw CloudClientError.credentialStorage
        }

        let addStatus = backing.add(data: data, service: service, account: origin)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            guard backing.update(data: data, service: service, account: origin) == errSecSuccess else {
                throw CloudClientError.credentialStorage
            }
        default:
            throw CloudClientError.credentialStorage
        }
    }
}
