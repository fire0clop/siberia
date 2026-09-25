import CryptoKit
import XCTest
@testable import Siberia

final class E2ECryptoTests: XCTestCase {

	/// Ядро схемы: путь создателя и путь собеседника дают ОДИН ключ чата.
	func testCreatorAndPeerDeriveSameKey() throws {
		let peerIdentity = Curve25519.KeyAgreement.PrivateKey()
		let eph = Curve25519.KeyAgreement.PrivateKey()
		let chatId = 777

		let creatorKey = try E2ECore.creatorChatKey(
			ephPriv: eph, peerIdentityPub: peerIdentity.publicKey, chatId: chatId
		)
		let peerKey = try E2ECore.peerChatKey(
			identityPriv: peerIdentity, ephPub: eph.publicKey, chatId: chatId
		)

		let a = creatorKey.withUnsafeBytes { Data($0) }
		let b = peerKey.withUnsafeBytes { Data($0) }
		XCTAssertEqual(a, b, "оба пути X25519 обязаны сходиться в один ключ")
		XCTAssertEqual(a.count, 32)
	}

	/// Разные чаты → разные ключи (info в HKDF включает chatId).
	func testDifferentChatsDifferentKeys() throws {
		let peerIdentity = Curve25519.KeyAgreement.PrivateKey()
		let eph = Curve25519.KeyAgreement.PrivateKey()
		let k1 = try E2ECore.creatorChatKey(ephPriv: eph, peerIdentityPub: peerIdentity.publicKey, chatId: 1)
		let k2 = try E2ECore.creatorChatKey(ephPriv: eph, peerIdentityPub: peerIdentity.publicKey, chatId: 2)
		XCTAssertNotEqual(k1.withUnsafeBytes { Data($0) }, k2.withUnsafeBytes { Data($0) })
	}

	func testEncryptDecryptRoundtrip() throws {
		let key = SymmetricKey(size: .bits256)
		let text = "Секретное сообщение 🔒 с эмодзи и **разметкой**"
		let blob = try E2ECore.encrypt(text: text, key: key)
		XCTAssertEqual(E2ECore.decrypt(blobB64: blob, key: key), text)
		// Каждое шифрование — свой nonce: блобы разные
		let blob2 = try E2ECore.encrypt(text: text, key: key)
		XCTAssertNotEqual(blob, blob2)
	}

	func testWrongKeyFailsClosed() throws {
		let blob = try E2ECore.encrypt(text: "тайна", key: SymmetricKey(size: .bits256))
		XCTAssertNil(E2ECore.decrypt(blobB64: blob, key: SymmetricKey(size: .bits256)))
	}

	func testTamperedBlobFailsClosed() throws {
		let key = SymmetricKey(size: .bits256)
		let blob = try E2ECore.encrypt(text: "целостность", key: key)
		var raw = Data(base64Encoded: blob)!
		raw[raw.count - 1] ^= 0xFF  // портим байт тега
		XCTAssertNil(E2ECore.decrypt(blobB64: raw.base64EncodedString(), key: key))
		XCTAssertNil(E2ECore.decrypt(blobB64: "не base64 вовсе", key: key))
	}

	func testPublicKeySerializationRoundtrip() {
		let priv = Curve25519.KeyAgreement.PrivateKey()
		let b64 = E2ECore.publicKeyB64(priv)
		let restored = E2ECore.publicKey(fromB64: b64)
		XCTAssertEqual(restored?.rawRepresentation, priv.publicKey.rawRepresentation)
		XCTAssertNil(E2ECore.publicKey(fromB64: "AAAA"))  // не 32 байта
	}

	/// Полный сценарий «два клиента»: создатель шифрует — собеседник читает.
	func testTwoClientConversation() throws {
		let peerIdentity = Curve25519.KeyAgreement.PrivateKey()
		let eph = Curve25519.KeyAgreement.PrivateKey()
		let chatId = 42

		let creatorKey = try E2ECore.creatorChatKey(
			ephPriv: eph, peerIdentityPub: peerIdentity.publicKey, chatId: chatId
		)
		// «Сервер» передал peer'у только eph_pub (base64) — как в e2e_handshake
		let ephPubB64 = E2ECore.publicKeyB64(eph)
		let peerKey = try E2ECore.peerChatKey(
			identityPriv: peerIdentity,
			ephPub: E2ECore.publicKey(fromB64: ephPubB64)!,
			chatId: chatId
		)

		let blob = try E2ECore.encrypt(text: "привет с той стороны", key: creatorKey)
		XCTAssertEqual(E2ECore.decrypt(blobB64: blob, key: peerKey), "привет с той стороны")
	}
}

extension E2ECryptoTests {

	private func b64key() -> String {
		Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
	}

	func testSafetyNumberOrderIndependent() {
		let a = b64key(); let b = b64key()
		let ab = E2ECore.safetyNumber(a, b)
		let ba = E2ECore.safetyNumber(b, a)
		XCTAssertNotNil(ab)
		XCTAssertEqual(ab, ba, "число должно быть одинаковым независимо от порядка сторон")
	}

	func testSafetyNumberFormat() {
		let sn = E2ECore.safetyNumber(b64key(), b64key())!
		let groups = sn.split(separator: " ")
		XCTAssertEqual(groups.count, 12)
		for g in groups {
			XCTAssertEqual(g.count, 5)
			XCTAssertTrue(g.allSatisfy(\.isNumber))
		}
	}

	func testSafetyNumberDiffersOnKeySubstitution() {
		let mine = b64key()
		let realPeer = b64key()
		let attacker = b64key()   // сервер подсунул свой ключ вместо ключа собеседника
		let honest = E2ECore.safetyNumber(mine, realPeer)
		let mitm   = E2ECore.safetyNumber(mine, attacker)
		XCTAssertNotEqual(honest, mitm, "подмена ключа обязана менять отпечаток — иначе MITM незаметен")
	}

	func testSafetyNumberRejectsBadInput() {
		XCTAssertNil(E2ECore.safetyNumber("not-base64", b64key()))
		XCTAssertNil(E2ECore.safetyNumber(Data([1,2,3]).base64EncodedString(), b64key()))
	}
}
