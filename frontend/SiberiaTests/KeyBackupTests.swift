import CryptoKit
import XCTest
@testable import Siberia

/// Бэкап identity-ключа под пассфразу (PBKDF2 → AES-GCM).
final class KeyBackupTests: XCTestCase {

	func testWrapUnwrapRoundtrip() {
		let secret = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
		let w = KeyBackupCrypto.wrap(secret: secret, passphrase: "correct horse battery staple", iterations: 120_000)!
		let back = KeyBackupCrypto.unwrap(
			ciphertextB64: w.ciphertext, saltB64: w.salt, iterations: w.iterations,
			passphrase: "correct horse battery staple"
		)
		XCTAssertEqual(back, secret)
	}

	func testWrongPassphraseFails() {
		let secret = Curve25519.KeyAgreement.PrivateKey().rawRepresentation
		let w = KeyBackupCrypto.wrap(secret: secret, passphrase: "верная пассфраза", iterations: 120_000)!
		XCTAssertNil(KeyBackupCrypto.unwrap(
			ciphertextB64: w.ciphertext, saltB64: w.salt, iterations: w.iterations,
			passphrase: "неверная пассфраза"
		))
	}

	func testSaltIsRandomPerWrap() {
		let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
		let a = KeyBackupCrypto.wrap(secret: secret, passphrase: "p", iterations: 120_000)!
		let b = KeyBackupCrypto.wrap(secret: secret, passphrase: "p", iterations: 120_000)!
		XCTAssertNotEqual(a.salt, b.salt)       // разная соль
		XCTAssertNotEqual(a.ciphertext, b.ciphertext)  // → разный шифротекст
	}

	func testDerivedKeyDeterministicForSameInputs() {
		let salt = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
		let k1 = KeyBackupCrypto.deriveKey(passphrase: "pw", salt: salt, iterations: 100_000)!
		let k2 = KeyBackupCrypto.deriveKey(passphrase: "pw", salt: salt, iterations: 100_000)!
		XCTAssertEqual(k1.withUnsafeBytes { Data($0) }, k2.withUnsafeBytes { Data($0) })
		let k3 = KeyBackupCrypto.deriveKey(passphrase: "pw2", salt: salt, iterations: 100_000)!
		XCTAssertNotEqual(k1.withUnsafeBytes { Data($0) }, k3.withUnsafeBytes { Data($0) })
	}
}
