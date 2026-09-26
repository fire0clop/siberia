import CryptoKit
import XCTest
@testable import Siberia

/// Double Ratchet: двухсторонний обмен, DH-рэтчет, сообщения вне порядка,
/// пропущенные ключи, отказ на подмену. Ядро — самая критичная крипта стадии 4.
final class DoubleRatchetTests: XCTestCase {

	/// Общий секрет + первая ratchet-пара Bob'а (в бою — из X3DH-lite).
	private func session() -> (alice: DoubleRatchetState, bob: DoubleRatchetState) {
		let sk = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
		let bobRatchet = Curve25519.KeyAgreement.PrivateKey()
		let alice = DoubleRatchet.initSender(
			sharedSecret: sk, peerRatchetPub: bobRatchet.publicKey.rawRepresentation
		)!
		let bob = DoubleRatchet.initReceiver(
			sharedSecret: sk,
			ownRatchetPriv: bobRatchet.rawRepresentation,
			ownRatchetPub: bobRatchet.publicKey.rawRepresentation
		)
		return (alice, bob)
	}

	func testSingleMessageAliceToBob() {
		var (a, b) = session()
		let env = DoubleRatchet.encrypt(state: &a, plaintext: "привет 🔒")!
		XCTAssertEqual(DoubleRatchet.decrypt(state: &b, envelopeB64: env), "привет 🔒")
	}

	func testPingPongWithDHRatchet() {
		var (a, b) = session()
		// A→B, затем B→A (запускает DH-рэтчет), затем A→B снова
		let m1 = DoubleRatchet.encrypt(state: &a, plaintext: "1 от A")!
		XCTAssertEqual(DoubleRatchet.decrypt(state: &b, envelopeB64: m1), "1 от A")

		let m2 = DoubleRatchet.encrypt(state: &b, plaintext: "2 от B")!
		XCTAssertEqual(DoubleRatchet.decrypt(state: &a, envelopeB64: m2), "2 от B")

		let m3 = DoubleRatchet.encrypt(state: &a, plaintext: "3 от A")!
		XCTAssertEqual(DoubleRatchet.decrypt(state: &b, envelopeB64: m3), "3 от A")

		let m4 = DoubleRatchet.encrypt(state: &b, plaintext: "4 от B")!
		XCTAssertEqual(DoubleRatchet.decrypt(state: &a, envelopeB64: m4), "4 от B")
	}

	func testOutOfOrderWithinChain() {
		var (a, b) = session()
		let e1 = DoubleRatchet.encrypt(state: &a, plaintext: "one")!
		let e2 = DoubleRatchet.encrypt(state: &a, plaintext: "two")!
		let e3 = DoubleRatchet.encrypt(state: &a, plaintext: "three")!
		// Приходят в порядке 3,1,2 — пропущенные ключи должны сохраниться
		XCTAssertEqual(DoubleRatchet.decrypt(state: &b, envelopeB64: e3), "three")
		XCTAssertEqual(DoubleRatchet.decrypt(state: &b, envelopeB64: e1), "one")
		XCTAssertEqual(DoubleRatchet.decrypt(state: &b, envelopeB64: e2), "two")
	}

	func testSkippedAcrossRatchet() {
		var (a, b) = session()
		// A шлёт два, B получает только первое, отвечает, потом приходит второе (старая цепочка)
		let a1 = DoubleRatchet.encrypt(state: &a, plaintext: "a1")!
		let a2 = DoubleRatchet.encrypt(state: &a, plaintext: "a2")!
		XCTAssertEqual(DoubleRatchet.decrypt(state: &b, envelopeB64: a1), "a1")
		let b1 = DoubleRatchet.encrypt(state: &b, plaintext: "b1")!
		XCTAssertEqual(DoubleRatchet.decrypt(state: &a, envelopeB64: b1), "b1")
		// запоздавшее a2 из предыдущей цепочки A всё ещё читается
		XCTAssertEqual(DoubleRatchet.decrypt(state: &b, envelopeB64: a2), "a2")
	}

	func testForwardSecrecyStateAdvances() {
		var (a, b) = session()
		let e1 = DoubleRatchet.encrypt(state: &a, plaintext: "секрет-1")!
		let stateAfter = b
		_ = DoubleRatchet.decrypt(state: &b, envelopeB64: e1)
		// Принимающая цепочка Bob продвинулась (chain key сменился) —
		// текущее состояние уже не тот ключ, что расшифровал e1.
		XCTAssertNotEqual(stateAfter.ckr, b.ckr)
	}

	func testTamperedCiphertextFails() {
		var (a, b) = session()
		let env = DoubleRatchet.encrypt(state: &a, plaintext: "целостность")!
		var raw = Data(base64Encoded: env)!
		raw[raw.count - 1] ^= 0xFF  // портим последний байт конверта
		XCTAssertNil(DoubleRatchet.decrypt(state: &b, envelopeB64: raw.base64EncodedString()))
		// Исходный конверт по-прежнему читается (состояние не испортилось)
		XCTAssertEqual(DoubleRatchet.decrypt(state: &b, envelopeB64: env), "целостность")
	}

	func testWrongADFails() {
		var (a, b) = session()
		let env = DoubleRatchet.encrypt(state: &a, plaintext: "с AAD", ad: Data("chat:1".utf8))!
		XCTAssertNil(DoubleRatchet.decrypt(state: &b, envelopeB64: env, ad: Data("chat:2".utf8)))
		XCTAssertEqual(DoubleRatchet.decrypt(state: &b, envelopeB64: env, ad: Data("chat:1".utf8)), "с AAD")
	}

	func testStateCodableRoundtrip() throws {
		var (a, _) = session()
		let env = DoubleRatchet.encrypt(state: &a, plaintext: "persist")!
		let data = try JSONEncoder().encode(a)
		let restored = try JSONDecoder().decode(DoubleRatchetState.self, from: data)
		XCTAssertEqual(a, restored)
		XCTAssertFalse(env.isEmpty)
	}
}
