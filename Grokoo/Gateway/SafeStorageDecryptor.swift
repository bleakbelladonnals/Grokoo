import CommonCrypto
import Foundation

struct SafeStorageDecryptor: Sendable {
    private static let prefix = Data("v10".utf8)
    private static let salt = Data("saltysalt".utf8)
    private static let iterations: UInt32 = 1003
    private static let keyLength = kCCKeySizeAES128
    private static let initializationVector = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    func decrypt(base64Ciphertext: String, password: String) throws -> String {
        guard let wrapped = Data(base64Encoded: base64Ciphertext),
              wrapped.count > Self.prefix.count,
              wrapped.prefix(Self.prefix.count) == Self.prefix else {
            throw GatewayFailure.unsupportedCiphertext
        }

        let passwordBytes = Array(password.utf8)
        var key = [UInt8](repeating: 0, count: Self.keyLength)
        let derivationStatus = Self.salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes,
                passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                Self.salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                Self.iterations,
                &key,
                key.count
            )
        }
        guard derivationStatus == kCCSuccess else {
            throw GatewayFailure.decryptionFailed
        }

        let encrypted = wrapped.dropFirst(Self.prefix.count)
        var plaintext = [UInt8](repeating: 0, count: encrypted.count + kCCBlockSizeAES128)
        var plaintextCount = 0
        let cryptStatus = key.withUnsafeBytes { keyBuffer in
            Self.initializationVector.withUnsafeBytes { ivBuffer in
                encrypted.withUnsafeBytes { encryptedBuffer in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBuffer.baseAddress,
                        key.count,
                        ivBuffer.baseAddress,
                        encryptedBuffer.baseAddress,
                        encrypted.count,
                        &plaintext,
                        plaintext.count,
                        &plaintextCount
                    )
                }
            }
        }
        guard cryptStatus == kCCSuccess,
              let cleartext = String(bytes: plaintext.prefix(plaintextCount), encoding: .utf8) else {
            throw GatewayFailure.decryptionFailed
        }
        return cleartext
    }
}
