import CryptoKit
import Foundation
import Security

// MARK: - ScoutDropIdentityError

enum ScoutDropIdentityError: LocalizedError {
    case keyGenerationFailed(String)
    case certificateCreationFailed(String)
    case keychainError(String)
    case signingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .keyGenerationFailed(msg): return "Key generation failed: \(msg)"
        case let .certificateCreationFailed(msg): return "Certificate creation failed: \(msg)"
        case let .keychainError(msg): return "Keychain error: \(msg)"
        case let .signingFailed(msg): return "Signing failed: \(msg)"
        }
    }
}

// MARK: - ScoutDropIdentity

enum ScoutDropIdentity {
    // MARK: - Constants

    private static let applicationTag = "com.scout.scoutdrop.identity"

    private static let oidEcPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let oidPrime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static let oidEcdsaWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
    private static let oidCommonName: [UInt8] = [0x55, 0x04, 0x03]

    // MARK: - Public API

    static func getOrCreateIdentity() throws -> SecIdentity {
        if let existing = try queryExistingIdentity() {
            return existing
        }

        let privateKey = try generateKeyPair()
        let certificate = try createSelfSignedCertificate(privateKey: privateKey)
        try importCertificate(certificate)

        guard let identity = try queryExistingIdentity() else {
            throw ScoutDropIdentityError.keychainError(
                "Identity not found after importing certificate"
            )
        }
        return identity
    }

    static func publicKeyHash(from trust: sec_trust_t) -> String? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        guard let certChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let leafCert = certChain.first
        else {
            NSLog("ScoutDropIdentity: failed to extract leaf certificate from trust")
            return nil
        }

        return publicKeyHashFromCertificate(leafCert)
    }

    static func publicKeyHash(from identity: SecIdentity) -> String? {
        var cert: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &cert)
        guard status == errSecSuccess, let certificate = cert else {
            NSLog("ScoutDropIdentity: failed to copy certificate from identity (status: %d)", status)
            return nil
        }

        return publicKeyHashFromCertificate(certificate)
    }

    // MARK: - Keychain Operations

    private static func queryExistingIdentity() throws -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrApplicationTag as String: applicationTag.data(using: .utf8)!,
            kSecReturnRef as String: true,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return (result as! SecIdentity)
        case errSecItemNotFound:
            return nil
        default:
            throw ScoutDropIdentityError.keychainError(
                "Failed to query keychain (status: \(status))"
            )
        }
    }

    private static func generateKeyPair() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: applicationTag.data(using: .utf8)!,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw ScoutDropIdentityError.keyGenerationFailed(message)
        }

        return privateKey
    }

    private static func importCertificate(_ certificateData: Data) throws {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData) else {
            throw ScoutDropIdentityError.certificateCreationFailed(
                "SecCertificateCreateWithData returned nil"
            )
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw ScoutDropIdentityError.keychainError(
                "Failed to add certificate to keychain (status: \(status))"
            )
        }
    }

    // MARK: - Key Hash

    private static func publicKeyHashFromCertificate(_ certificate: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(certificate) else {
            NSLog("ScoutDropIdentity: failed to extract public key from certificate")
            return nil
        }

        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(key, &error) as Data? else {
            NSLog("ScoutDropIdentity: failed to export public key")
            return nil
        }

        let digest = SHA256.hash(data: keyData)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Verification Code

    /// Derives a 6-digit verification code from two public key hashes.
    /// Both peers compute the same code independently (never transmitted).
    /// A MITM produces different key hashes on each side, yielding different codes.
    static func deriveVerificationCode(localKeyHash: String, peerKeyHash: String) -> String {
        // Canonical ordering ensures both sides compute the same input.
        let (first, second) = localKeyHash < peerKeyHash
            ? (localKeyHash, peerKeyHash)
            : (peerKeyHash, localKeyHash)
        let combined = Data((first + second).utf8)
        let digest = SHA256.hash(data: combined)
        // Take first 4 bytes as a UInt32, mod 1_000_000 for 6 digits.
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06d", value % 1_000_000)
    }

    // MARK: - Self-Signed Certificate

    private static func createSelfSignedCertificate(privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw ScoutDropIdentityError.certificateCreationFailed(
                "Failed to derive public key from private key"
            )
        }

        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw ScoutDropIdentityError.certificateCreationFailed(
                "Failed to export public key: \(message)"
            )
        }

        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        guard let notAfter = calendar.date(byAdding: .year, value: 10, to: now) else {
            throw ScoutDropIdentityError.certificateCreationFailed(
                "Failed to compute certificate expiry date"
            )
        }

        let tbsCertificate = buildTBSCertificate(
            publicKeyBytes: [UInt8](publicKeyData),
            notBefore: now,
            notAfter: notAfter
        )

        let tbsData = Data(tbsCertificate)
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsData as CFData,
            &error
        ) as Data? else {
            let message = error?.takeRetainedValue().localizedDescription ?? "unknown error"
            throw ScoutDropIdentityError.signingFailed(message)
        }

        let signatureAlgorithm = derSequence(
            derOID(oidEcdsaWithSHA256)
        )

        let certificate = derSequence(
            tbsCertificate
                + signatureAlgorithm
                + derBitString([UInt8](signature))
        )

        return Data(certificate)
    }

    private static func buildTBSCertificate(
        publicKeyBytes: [UInt8],
        notBefore: Date,
        notAfter: Date
    ) -> [UInt8] {
        // Version: v3 (integer 2, explicitly tagged [0])
        let version = derExplicitTag(0, derInteger([0x02]))

        // Serial: random 16-byte positive integer
        var serialBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes)
        serialBytes[0] &= 0x7F // clear high bit to ensure positive
        let serial = derInteger(serialBytes)

        // Signature algorithm
        let signatureAlgorithm = derSequence(derOID(oidEcdsaWithSHA256))

        // Issuer: CN=ScoutDrop
        let issuer = buildRDNSequence("ScoutDrop")

        // Validity
        let validity = derSequence(
            derGeneralizedTime(notBefore)
                + derGeneralizedTime(notAfter)
        )

        // Subject: CN=ScoutDrop
        let subject = buildRDNSequence("ScoutDrop")

        // SubjectPublicKeyInfo
        let algorithmIdentifier = derSequence(
            derOID(oidEcPublicKey)
                + derOID(oidPrime256v1)
        )
        let subjectPublicKeyInfo = derSequence(
            algorithmIdentifier
                + derBitString(publicKeyBytes)
        )

        return derSequence(
            version
                + serial
                + signatureAlgorithm
                + issuer
                + validity
                + subject
                + subjectPublicKeyInfo
        )
    }

    private static func buildRDNSequence(_ commonName: String) -> [UInt8] {
        let atv = derSequence(
            derOID(oidCommonName)
                + derUTF8String(commonName)
        )
        let rdn = derSet(atv)
        return derSequence(rdn)
    }

    // MARK: - DER Encoding Helpers (internal for testability)

    static func derLength(_ length: Int) -> [UInt8] {
        if length < 128 {
            return [UInt8(length)]
        }
        var remaining = length
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    static func derSequence(_ contents: [UInt8]) -> [UInt8] {
        return [0x30] + derLength(contents.count) + contents
    }

    static func derSet(_ contents: [UInt8]) -> [UInt8] {
        return [0x31] + derLength(contents.count) + contents
    }

    static func derOID(_ bytes: [UInt8]) -> [UInt8] {
        return [0x06] + derLength(bytes.count) + bytes
    }

    static func derInteger(_ bytes: [UInt8]) -> [UInt8] {
        var value = bytes
        if let first = value.first, first & 0x80 != 0 {
            value.insert(0x00, at: 0)
        }
        return [0x02] + derLength(value.count) + value
    }

    static func derBitString(_ bytes: [UInt8]) -> [UInt8] {
        let content = [UInt8(0x00)] + bytes // 0x00 = unused bits
        return [0x03] + derLength(content.count) + content
    }

    static func derUTF8String(_ string: String) -> [UInt8] {
        let bytes = [UInt8](string.utf8)
        return [0x0C] + derLength(bytes.count) + bytes
    }

    static func derGeneralizedTime(_ date: Date) -> [UInt8] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let timeString = formatter.string(from: date) + "Z"
        let bytes = [UInt8](timeString.utf8)
        return [0x18] + derLength(bytes.count) + bytes
    }

    static func derExplicitTag(_ tag: UInt8, _ contents: [UInt8]) -> [UInt8] {
        return [0xA0 | tag] + derLength(contents.count) + contents
    }
}
