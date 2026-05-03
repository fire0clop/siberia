// Core/Notifications/VoIPPushManager.swift
//
// PushKit-приёмник VoIP-пушей. Делает три вещи:
//   1. Регистрирует VoIP-токен и отправляет его на бэк (отдельно от обычного APNs)
//   2. Когда прилетает VoIP-пуш — СРАЗУ репортит звонок в CallKit (это блокирующее
//      требование Apple: если не зарепортить за ~5 сек, VoIP-токен будет отозван)
//   3. Передаёт payload в AppState, чтобы он подготовил состояние входящего звонка

import Foundation
import PushKit
import UIKit

final class VoIPPushManager: NSObject {

	static let shared = VoIPPushManager()
	private let registry = PKPushRegistry(queue: .main)

	private override init() { super.init() }

	/// Вызывается ОДИН раз в AppDelegate.didFinishLaunchingWithOptions.
	/// PushKit очень требователен — desiredPushTypes должны быть выставлены
	/// сразу при старте приложения, иначе ранние пуши теряются.
	func start() {
		registry.delegate = self
		registry.desiredPushTypes = [.voIP]
	}
}

// MARK: – PKPushRegistryDelegate

extension VoIPPushManager: PKPushRegistryDelegate {

	func pushRegistry(
		_ registry: PKPushRegistry,
		didUpdate pushCredentials: PKPushCredentials,
		for type: PKPushType
	) {
		guard type == .voIP else { return }
		let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
		Log.push.info("VoIP token received (length=\(token.count))")
		Task {
			do {
				try await PushTokenService.shared.register(token: token, kind: .voip)
				Log.push.info("VoIP token registered on backend")
			} catch {
				Log.push.error("VoIP token register failed: \(String(describing: error))")
			}
		}
	}

	func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
		Log.push.info("VoIP token invalidated")
	}

	/// КРИТИЧНО: пока этот метод не вернётся И мы не вызовем
	/// CXProvider.reportNewIncomingCall — нас могут убить.
	func pushRegistry(
		_ registry: PKPushRegistry,
		didReceiveIncomingPushWith payload: PKPushPayload,
		for type: PKPushType,
		completion: @escaping () -> Void
	) {
		guard type == .voIP else { completion(); return }

		let dict = payload.dictionaryPayload
		Log.calls.info("VoIP push received: \(dict)")

		let callId      = (dict["call_id"] as? Int) ?? (dict["call_id"] as? NSNumber)?.intValue ?? 0
		let callerId    = (dict["caller_id"] as? Int) ?? (dict["caller_id"] as? NSNumber)?.intValue ?? 0
		let callerName  = (dict["caller_name"] as? String) ?? "Неизвестный"
		let callerAvatar = dict["caller_avatar"] as? String
		let typeStr     = (dict["type"] as? String) ?? "audio"
		let callType: CallType = (typeStr == "video") ? .video : .audio

		// 1) Немедленно репортим в CallKit (БЛОКИРУЮЩЕЕ требование Apple)
		Task { @MainActor in
			CallKitManager.shared.reportIncoming(
				callId: callId,
				callerName: callerName,
				hasVideo: callType == .video
			) { _ in
				// 2) После того как iOS показал экран звонка — раздаём контекст AppState'у
				Task { @MainActor in
					AppState.shared?.prepareIncomingFromVoIPPush(
						callId: callId,
						callerId: callerId,
						callerName: callerName,
						callerAvatar: callerAvatar,
						type: callType
					)
					completion()
				}
			}
		}
	}
}
