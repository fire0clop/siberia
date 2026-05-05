// Features/Calls/CallKitManager.swift
//
// Интеграция с CallKit (системные экраны звонка, Recent Calls, lock-screen UI).
// Этот же объект — мост между CXProvider'ом и нашим AppState'ом: системные
// действия пользователя (нажал Accept / End на экране звонка) приходят сюда
// через делегат и далее транслируются в AppState.
//
// Маппинг: CallKit оперирует UUID'ами, у нас на бэке call_id — Int. Держим
// двусторонний словарь.

import Foundation
import CallKit
import AVFoundation
import UIKit

@MainActor
final class CallKitManager: NSObject {

	static let shared = CallKitManager()

	private let provider: CXProvider
	private let controller = CXCallController()

	private var uuidToCallId: [UUID: Int] = [:]
	private var callIdToUuid: [Int: UUID] = [:]

	private static let providerConfig: CXProviderConfiguration = {
		// init(localizedName:) — единственный способ выставить имя; новый init()
		// делает localizedName read-only.
		let cfg = CXProviderConfiguration(localizedName: "Siberia")
		cfg.supportsVideo = true
		cfg.maximumCallGroups = 1
		cfg.maximumCallsPerCallGroup = 1
		cfg.supportedHandleTypes = [.generic]
		cfg.includesCallsInRecents = true
		if let img = UIImage(named: "AppIcon") {
			cfg.iconTemplateImageData = img.pngData()
		}
		return cfg
	}()

	override init() {
		self.provider = CXProvider(configuration: Self.providerConfig)
		super.init()
		provider.setDelegate(self, queue: .main)
	}

	// MARK: – Public API

	/// Зарепортить системе ВХОДЯЩИЙ звонок. Вызывается либо из обработчика
	/// VoIP-пуша, либо из WS-обработчика (если push не пришёл, но WS живой).
	/// Должна выполниться в течение ~5 сек от прихода VoIP-пуша — иначе iOS
	/// отзывает VoIP-токен.
	func reportIncoming(
		callId: Int,
		callerName: String,
		hasVideo: Bool,
		completion: ((Error?) -> Void)? = nil
	) {
		// Если этому call_id уже сопоставлен UUID — переиспользуем
		let uuid = callIdToUuid[callId] ?? UUID()
		register(uuid: uuid, callId: callId)

		let update = CXCallUpdate()
		update.remoteHandle = CXHandle(type: .generic, value: callerName)
		update.localizedCallerName = callerName
		update.hasVideo = hasVideo
		update.supportsGrouping = false
		update.supportsUngrouping = false
		update.supportsHolding = false
		update.supportsDTMF = false

		provider.reportNewIncomingCall(with: uuid, update: update) { error in
			if let error {
				Log.calls.error("CallKit reportIncoming failed: \(String(describing: error))")
				// Чистим маппинг — звонок реально не зарегистрировался
				Task { @MainActor in self.unregister(callId: callId) }
			}
			completion?(error)
		}
	}

	/// Зарепортить ИСХОДЯЩИЙ звонок. Вызываем когда юзер тапает 📞 в чате.
	func reportOutgoing(callId: Int, peerName: String, hasVideo: Bool) {
		let uuid = UUID()
		register(uuid: uuid, callId: callId)

		let handle = CXHandle(type: .generic, value: peerName)
		let action = CXStartCallAction(call: uuid, handle: handle)
		action.isVideo = hasVideo
		controller.request(CXTransaction(action: action)) { error in
			if let error { Log.calls.error("CallKit startCall failed: \(String(describing: error))") }
		}
		provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
	}

	/// Когда WebRTC реально соединился (ICE.connected) — говорим CallKit'у
	/// что звонок «поднят». Иначе он будет вечно «звонит».
	func reportConnected(callId: Int) {
		guard let uuid = callIdToUuid[callId] else { return }
		provider.reportOutgoingCall(with: uuid, connectedAt: Date())
	}

	/// Завершить звонок СО СВОЕЙ стороны (наш UI нажал End).
	/// Это инициирует системное действие End через controller — затем CXEndCallAction
	/// прилетит в наш делегат, и мы там разрулим логику завершения.
	func endCall(callId: Int) {
		guard let uuid = callIdToUuid[callId] else { return }
		let action = CXEndCallAction(call: uuid)
		controller.request(CXTransaction(action: action)) { error in
			if let error { Log.calls.error("CallKit endCall failed: \(String(describing: error))") }
		}
	}

	/// Закрыть звонок без запроса к контроллеру — когда удалённая сторона
	/// уже завершила (нам пришло call_ended/declined через WS).
	func reportRemoteEnd(callId: Int, reason: CXCallEndedReason) {
		guard let uuid = callIdToUuid[callId] else { return }
		provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
		unregister(callId: callId)
	}

	/// Системный mute (lock screen / control center) поменялся → синхронизируем
	/// с состоянием микрофона в CallManager.
	func updateMuteState(callId: Int, muted: Bool) {
		guard let uuid = callIdToUuid[callId] else { return }
		let action = CXSetMutedCallAction(call: uuid, muted: muted)
		controller.request(CXTransaction(action: action)) { _ in }
	}

	// MARK: – Internal

	private func register(uuid: UUID, callId: Int) {
		uuidToCallId[uuid] = callId
		callIdToUuid[callId] = uuid
	}

	private func unregister(callId: Int) {
		if let uuid = callIdToUuid.removeValue(forKey: callId) {
			uuidToCallId.removeValue(forKey: uuid)
		}
	}
}

// MARK: – CXProviderDelegate

extension CallKitManager: CXProviderDelegate {

	nonisolated func providerDidReset(_ provider: CXProvider) {
		Task { @MainActor in
			self.uuidToCallId.removeAll()
			self.callIdToUuid.removeAll()
			await AppState.shared?.forceTeardownAllCalls()
		}
	}

	nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
		Task { @MainActor in
			guard let callId = self.uuidToCallId[action.callUUID] else {
				action.fail(); return
			}
			await AppState.shared?.callKitDidAccept(callId: callId)
			action.fulfill()
		}
	}

	nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
		Task { @MainActor in
			guard let callId = self.uuidToCallId[action.callUUID] else {
				action.fail(); return
			}
			await AppState.shared?.callKitDidEnd(callId: callId)
			self.unregister(callId: callId)
			action.fulfill()
		}
	}

	nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
		Task { @MainActor in
			AppState.shared?.callManager?.setMuted(action.isMuted)
			action.fulfill()
		}
	}

	nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
		action.fulfill()
	}

	nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
		Task { @MainActor in
			AppState.shared?.callManager?.didActivateAudioSession()
		}
	}

	nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
		Task { @MainActor in
			AppState.shared?.callManager?.didDeactivateAudioSession()
		}
	}

	nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
		action.fail()
	}
}
