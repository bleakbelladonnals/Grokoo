import Foundation
import Security

protocol KeychainPasswordReading: Sendable {
    func password(service: String) async throws -> String
}

struct SecurityKeychainReader: KeychainPasswordReading, Sendable {
    func password(service: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecMatchLimit: kSecMatchLimitOne,
                kSecReturnData: true,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data,
                      let password = String(data: data, encoding: .utf8),
                      !password.isEmpty else {
                    throw GatewayFailure.keychainUnavailable(status: status)
                }
                return password
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                throw GatewayFailure.keychainDenied
            default:
                throw GatewayFailure.keychainUnavailable(status: status)
            }
        }.value
    }
}

struct DesktopSessionLoader: DesktopSessionLoading, Sendable {
    static let keychainService = "Grok Bot Safe Storage"

    let descriptorURL: URL
    let keychain: any KeychainPasswordReading
    let decryptor: SafeStorageDecryptor

    init(
        descriptorURL: URL = Self.defaultDescriptorURL(),
        keychain: any KeychainPasswordReading = SecurityKeychainReader(),
        decryptor: SafeStorageDecryptor = SafeStorageDecryptor()
    ) {
        self.descriptorURL = descriptorURL
        self.keychain = keychain
        self.decryptor = decryptor
    }

    static func defaultDescriptorURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Grok Bot", isDirectory: true)
            .appendingPathComponent("gateway-descriptor.json", isDirectory: false)
    }

    func load() async throws -> DesktopSession {
        let url = descriptorURL
        let descriptorData: Data
        do {
            descriptorData = try await Task.detached(priority: .userInitiated) {
                try Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
        } catch {
            throw GatewayFailure.descriptorMissing
        }

        let encrypted = try Self.encryptedPayload(from: descriptorData)
        let password = try await keychain.password(service: Self.keychainService)
        let cleartext = try decryptor.decrypt(base64Ciphertext: encrypted, password: password)
        return try Self.session(fromCleartext: cleartext)
    }

    static func encryptedPayload(from data: Data) throws -> String {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GatewayFailure.unsupportedDescriptor
        }
        guard let root = value as? [String: Any] else {
            throw GatewayFailure.unsupportedDescriptor
        }
        let version = (root["version"] as? NSNumber)?.intValue
        guard version == nil || version == 1 || version == 2 else {
            throw GatewayFailure.unsupportedDescriptor
        }
        if version == 2 {
            return try encryptedV2Entry(root["entries"])
        }
        guard let encrypted = nonEmptyString(root["encrypted"]) else {
            throw GatewayFailure.unsupportedDescriptor
        }
        return encrypted
    }

    static func session(fromCleartext cleartext: String) throws -> DesktopSession {
        guard let data = cleartext.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let baseURL = nonEmptyString(root["baseUrl"]),
              let token = nonEmptyString(root["token"]) else {
            throw GatewayFailure.invalidSession
        }
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let gatewayURL = URL(string: trimmed),
              let scheme = gatewayURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              gatewayURL.host != nil else {
            throw GatewayFailure.invalidURL
        }
        var headers: [String: String] = [:]
        if let rawHeaders = root["headers"] as? [String: Any] {
            for (key, value) in rawHeaders {
                if let string = nonEmptyString(value) { headers[key] = string }
            }
        }
        return DesktopSession(gatewayURL: gatewayURL, bearerToken: token, routeHeaders: headers)
    }

    private static func encryptedV2Entry(_ value: Any?) throws -> String {
        if let direct = nonEmptyString(value) { return direct }
        guard let entries = value as? [String: Any], entries.count == 1,
              let entry = entries.values.first else {
            throw GatewayFailure.unsupportedDescriptor
        }
        if let direct = nonEmptyString(entry) { return direct }
        guard let record = entry as? [String: Any],
              let encrypted = nonEmptyString(record["encrypted"]) else {
            throw GatewayFailure.unsupportedDescriptor
        }
        return encrypted
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}
