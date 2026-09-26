// Core/Crypto/DoubleRatchet.swift
//
// Double Ratchet (спецификация Signal) для парных (1-на-1) сессий между двумя
// устройствами. Примитивы Apple CryptoKit:
//   DH      — X25519 (Curve25519.KeyAgreement)
//   KDF_RK  — HKDF-SHA256 (salt = root key, ikm = DH-выход) → root' + chain key
//   KDF_CK  — HMAC-SHA256 (константы 0x01/0x02) → message key + chain key'
//   AEAD    — AES-GCM (ключ сообщения одноразовый; header в AAD)
//
// Даёт forward secrecy (ключ каждого сообщения выводится и стирается) и
// post-compromise security (DH-рэтчет на каждом «повороте» диалога).
// Состояние DoubleRatchetState сериализуемо (Codable) — для хранения в Keychain.
//
// Ссылки на алгоритм: Signal "The Double Ratchet Algorithm", §3.

import CryptoKit
import Foundation

// MARK: – Сериализуемое состояние сессии

struct DoubleRatchetState: Codable, Equatable {
	var rk: Data                 // root key (32)
	var cks: Data?               // sending chain key
	var ckr: Data?               // receiving chain key
	var dhsPriv: Data            // наш ratchet-приватный (raw 32)
	var dhsPub: Data             // наш ratchet-публичный
	var dhr: Data?               // их ratchet-публичный
	var ns: Int                  // номер в текущей отправляющей цепочке
	var nr: Int                  // номер в текущей принимающей цепочке
	var pn: Int                  // длина предыдущей отправляющей цепочки
	var skipped: [String: Data]  // "их_dh_pub_b64:N" → message key (пропущенные)
}

// MARK: – Ядро

enum DoubleRatchet {

	static let maxSkip = 1000            // защита от DoS: не пропускаем больше подряд
	static let rkInfo = Data("siberia-dr-rk-v1".utf8)

	// ── примитивы ────────────────────────────────────────────────────────────

	private static func generateDH() -> Curve25519.KeyAgreement.PrivateKey {
		Curve25519.KeyAgreement.PrivateKey()
	}

	private static func dh(privRaw: Data, pubRaw: Data) -> Data? {
		guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privRaw),
		      let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubRaw),
		      let ss = try? priv.sharedSecretFromKeyAgreement(with: pub)
		else { return nil }
		return ss.withUnsafeBytes { Data($0) }
	}

	/// KDF_RK: (rk, dh) → (rk', chainKey). HKDF-SHA256, salt=rk, ikm=dh.
	private static func kdfRK(rk: Data, dhOut: Data) -> (Data, Data) {
		let okm = HKDF<SHA256>.deriveKey(
			inputKeyMaterial: SymmetricKey(data: dhOut),
			salt: rk,
			info: rkInfo,
			outputByteCount: 64
		).withUnsafeBytes { Data($0) }
		return (Data(okm.prefix(32)), Data(okm.suffix(32)))
	}

	/// KDF_CK: chainKey → (chainKey', messageKey). HMAC-SHA256 c 0x02/0x01.
	private static func kdfCK(ck: Data) -> (Data, Data) {
		let key = SymmetricKey(data: ck)
		let mk = HMAC<SHA256>.authenticationCode(for: Data([0x01]), using: key)
		let nextCK = HMAC<SHA256>.authenticationCode(for: Data([0x02]), using: key)
		return (Data(nextCK), Data(mk))
	}

	// ── header / envelope ─────────────────────────────────────────────────────

	private static func headerData(dhPub: Data, pn: Int, n: Int) -> Data {
		// Детерминированная сериализация для AAD (важно: одинакова у обеих сторон)
		(try? JSONSerialization.data(
			withJSONObject: ["dh": dhPub.base64EncodedString(), "pn": pn, "n": n],
			options: [.sortedKeys]
		)) ?? Data()
	}

	private static func skipKey(_ dhPub: Data, _ n: Int) -> String {
		"\(dhPub.base64EncodedString()):\(n)"
	}

	// ── инициализация ─────────────────────────────────────────────────────────

	/// Инициатор (Alice): знает общий секрет SK и первый ratchet-pub собеседника.
	static func initSender(sharedSecret sk: Data, peerRatchetPub: Data) -> DoubleRatchetState? {
		let dhs = generateDH()
		let dhsPriv = dhs.rawRepresentation
		let dhsPub = dhs.publicKey.rawRepresentation
		guard let dhOut = dh(privRaw: dhsPriv, pubRaw: peerRatchetPub) else { return nil }
		let (rk, cks) = kdfRK(rk: sk, dhOut: dhOut)
		return DoubleRatchetState(
			rk: rk, cks: cks, ckr: nil,
			dhsPriv: dhsPriv, dhsPub: dhsPub, dhr: peerRatchetPub,
			ns: 0, nr: 0, pn: 0, skipped: [:]
		)
	}

	/// Получатель (Bob): знает SK и СВОЮ первую ratchet-пару (её pub Alice уже
	/// использовала как peerRatchetPub). Отправляющая цепочка появится после
	/// первого входящего сообщения (DH-рэтчет).
	static func initReceiver(sharedSecret sk: Data, ownRatchetPriv: Data, ownRatchetPub: Data) -> DoubleRatchetState {
		DoubleRatchetState(
			rk: sk, cks: nil, ckr: nil,
			dhsPriv: ownRatchetPriv, dhsPub: ownRatchetPub, dhr: nil,
			ns: 0, nr: 0, pn: 0, skipped: [:]
		)
	}

	// ── шифрование ────────────────────────────────────────────────────────────

	/// Шифрует plaintext, продвигая отправляющую цепочку. Возвращает base64-конверт
	/// {dh,pn,n,ct}. ad — внешние associated data (например, id участников).
	static func encrypt(state: inout DoubleRatchetState, plaintext: String, ad: Data = Data()) -> String? {
		guard let cks = state.cks else { return nil }
		let (nextCK, mk) = kdfCK(ck: cks)
		state.cks = nextCK
		let header = headerData(dhPub: state.dhsPub, pn: state.pn, n: state.ns)
		let n = state.ns
		state.ns += 1
		guard let box = try? AES.GCM.seal(Data(plaintext.utf8), using: SymmetricKey(data: mk), authenticating: ad + header),
		      let combined = box.combined else { return nil }
		let env: [String: Any] = [
			"dh": state.dhsPub.base64EncodedString(),
			"pn": state.pn,
			"n": n,
			"ct": combined.base64EncodedString(),
		]
		return (try? JSONSerialization.data(withJSONObject: env))?.base64EncodedString()
	}

	// ── расшифровка ───────────────────────────────────────────────────────────

	static func decrypt(state: inout DoubleRatchetState, envelopeB64: String, ad: Data = Data()) -> String? {
		guard let envData = Data(base64Encoded: envelopeB64),
		      let env = try? JSONSerialization.jsonObject(with: envData) as? [String: Any],
		      let dhB64 = env["dh"] as? String, let dhr = Data(base64Encoded: dhB64),
		      let pn = env["pn"] as? Int,
		      let n = env["n"] as? Int,
		      let ctB64 = env["ct"] as? String, let combined = Data(base64Encoded: ctB64)
		else { return nil }

		let header = headerData(dhPub: dhr, pn: pn, n: n)

		// 1) пропущенный ранее ключ?
		if let mk = state.skipped[skipKey(dhr, n)] {
			guard let pt = open(combined, mk: mk, ad: ad + header) else { return nil }
			state.skipped[skipKey(dhr, n)] = nil
			return pt
		}

		var working = state  // работаем на копии — при ошибке состояние не портим

		// 2) новый ratchet-pub собеседника → досткипить старую цепочку и сделать DH-рэтчет
		if working.dhr == nil || dhr != working.dhr! {
			if !skipMessageKeys(&working, until: pn) { return nil }
			if !dhRatchet(&working, theirDH: dhr) { return nil }
		}

		// 3) досткипить в текущей принимающей цепочке до n
		if !skipMessageKeys(&working, until: n) { return nil }

		guard let ckr = working.ckr else { return nil }
		let (nextCK, mk) = kdfCK(ck: ckr)
		working.ckr = nextCK
		working.nr += 1

		guard let pt = open(combined, mk: mk, ad: ad + header) else { return nil }
		state = working  // фиксируем продвижение только при успешной расшифровке
		return pt
	}

	private static func open(_ combined: Data, mk: Data, ad: Data) -> String? {
		guard let box = try? AES.GCM.SealedBox(combined: combined),
		      let pt = try? AES.GCM.open(box, using: SymmetricKey(data: mk), authenticating: ad)
		else { return nil }
		return String(data: pt, encoding: .utf8)
	}

	/// Складывает message-ключи текущей принимающей цепочки до номера `until`
	/// в skipped (для сообщений, пришедших не по порядку). false — превышен лимит.
	private static func skipMessageKeys(_ state: inout DoubleRatchetState, until: Int) -> Bool {
		guard let ckr = state.ckr, let dhr = state.dhr else { return true }
		if state.nr + maxSkip < until { return false }
		var ck = ckr
		while state.nr < until {
			let (nextCK, mk) = kdfCK(ck: ck)
			state.skipped[skipKey(dhr, state.nr)] = mk
			ck = nextCK
			state.nr += 1
		}
		state.ckr = ck
		return true
	}

	/// DH-рэтчет: смена принимающей и отправляющей цепочек на новый ratchet-pub.
	private static func dhRatchet(_ state: inout DoubleRatchetState, theirDH: Data) -> Bool {
		state.pn = state.ns
		state.ns = 0
		state.nr = 0
		state.dhr = theirDH
		guard let dhOut1 = dh(privRaw: state.dhsPriv, pubRaw: theirDH) else { return false }
		let (rk1, ckr) = kdfRK(rk: state.rk, dhOut: dhOut1)
		state.rk = rk1
		state.ckr = ckr
		let newDHs = generateDH()
		state.dhsPriv = newDHs.rawRepresentation
		state.dhsPub = newDHs.publicKey.rawRepresentation
		guard let dhOut2 = dh(privRaw: state.dhsPriv, pubRaw: theirDH) else { return false }
		let (rk2, cks) = kdfRK(rk: state.rk, dhOut: dhOut2)
		state.rk = rk2
		state.cks = cks
		return true
	}
}
