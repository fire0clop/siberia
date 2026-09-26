// Core/Crypto/KeyBackup.swift
//
// Стадия 4b: бэкап identity-ключа под ПАССФРАЗУ.
//   ключ = PBKDF2-HMAC-SHA256(passphrase, salt, iterations) → 32 байта
//   бэкап = AES-GCM(identity_priv, ключ)  (combined = nonce||ct||tag)
// Сервер хранит только ciphertext+соль+итерации; пассфразы и ключа не видит.
// PBKDF2 берём из CommonCrypto (в CryptoKit парольного KDF нет).

import CommonCrypto
import CryptoKit
import Foundation

enum KeyBackupCrypto {

	static let defaultIterations = 210_000

	/// PBKDF2-HMAC-SHA256 → SymmetricKey(32). nil при пустых входных данных.
	static func deriveKey(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey? {
		guard !passphrase.isEmpty, !salt.isEmpty, iterations > 0 else { return nil }
		let pass = Array(passphrase.utf8)
		var out = [UInt8](repeating: 0, count: 32)
		let status = salt.withUnsafeBytes { saltPtr -> Int32 in
			CCKeyDerivationPBKDF(
				CCPBKDFAlgorithm(kCCPBKDF2),
				pass, pass.count,
				saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
				CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
				UInt32(iterations),
				&out, out.count
			)
		}
		guard status == kCCSuccess else { return nil }
		return SymmetricKey(data: Data(out))
	}

	/// Заворачивает secret (например, identity_priv) под пассфразу.
	/// Возвращает (ciphertextB64, saltB64, iterations).
	static func wrap(secret: Data, passphrase: String,
	                 iterations: Int = defaultIterations) -> (ciphertext: String, salt: String, iterations: Int)? {
		var saltBytes = [UInt8](repeating: 0, count: 16)
		guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else { return nil }
		let salt = Data(saltBytes)
		guard let key = deriveKey(passphrase: passphrase, salt: salt, iterations: iterations),
		      let box = try? AES.GCM.seal(secret, using: key),
		      let combined = box.combined
		else { return nil }
		return (combined.base64EncodedString(), salt.base64EncodedString(), iterations)
	}

	/// Разворачивает бэкап. nil при неверной пассфразе/повреждении.
	static func unwrap(ciphertextB64: String, saltB64: String, iterations: Int, passphrase: String) -> Data? {
		guard let salt = Data(base64Encoded: saltB64),
		      let combined = Data(base64Encoded: ciphertextB64),
		      let key = deriveKey(passphrase: passphrase, salt: salt, iterations: iterations),
		      let box = try? AES.GCM.SealedBox(combined: combined),
		      let secret = try? AES.GCM.open(box, using: key)
		else { return nil }
		return secret
	}
}
