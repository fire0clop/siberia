// Features/Calls/CallManager.swift
//
// Координатор одного звонка: владеет одним RTCPeerConnection, локальными треками
// (audio + опц. video), форвардит SDP/ICE через CallSignaling, обновляет
// ActiveCall.phase когда соединение реально готово.
//
// Один экземпляр на один звонок. После .end() выкидывается, делается новый.

import Foundation
import AVFoundation
import WebRTC      // через SPM https://github.com/stasel/WebRTC.git

@MainActor
final class CallManager: NSObject {

	// MARK: – Конфиг

	/// STUN — публичные гугловские. Когда поднимешь свой coturn, добавь сюда
	/// RTCIceServer(urlStrings: ["turn:siberia.app:3478"], username: "...", credential: "...")
	private static let iceServers: [RTCIceServer] = [
		RTCIceServer(urlStrings: [
			"stun:stun.l.google.com:19302",
			"stun:stun1.l.google.com:19302",
		]),
		// TODO: turn — подставить когда задеплоим coturn:
		// RTCIceServer(urlStrings: ["turn:turn.siberia.app:3478"],
		//              username: "<user>", credential: "<secret>")
	]

	// MARK: – State

	let activeCall: ActiveCall
	private let signaling: CallSignaling
	private let peerId: Int  // user_id второй стороны — для адресации сигналинга

	// WebRTC core
	private static let factory: RTCPeerConnectionFactory = {
		RTCInitializeSSL()
		let enc = RTCDefaultVideoEncoderFactory()
		let dec = RTCDefaultVideoDecoderFactory()
		return RTCPeerConnectionFactory(encoderFactory: enc, decoderFactory: dec)
	}()

	private var pc: RTCPeerConnection?
	private var localAudioTrack: RTCAudioTrack?
	private var localVideoTrack: RTCVideoTrack?
	private var remoteVideoTrack: RTCVideoTrack?
	private var videoCapturer: RTCCameraVideoCapturer?

	// Кандидаты, прилетевшие до того как remoteDescription будет установлен —
	// складываем в очередь, проигрываем после setRemote.
	private var pendingRemoteIce: [RTCIceCandidate] = []
	private var hasRemoteDescription = false

	// Live-views — публикуются наружу для подключения к UI
	private(set) var localRenderer:  RTCMTLVideoView?
	private(set) var remoteRenderer: RTCMTLVideoView?

	// MARK: – Init

	init(activeCall: ActiveCall, peerId: Int, signaling: CallSignaling) {
		self.activeCall = activeCall
		self.peerId = peerId
		self.signaling = signaling
		super.init()
	}

	// MARK: – Lifecycle

	/// Поднимаем PeerConnection, аудио/видео-треки, настраиваем аудиосессию.
	/// Дальше:
	///   - если iAmCaller: создаём оффер, шлём его, ждём ответа
	///   - если callee: ждём оффер из сигналинга (см. `handleRemoteOffer`)
	func start() async {
		configureAudioSession()

		let config = RTCConfiguration()
		config.iceServers = Self.iceServers
		config.sdpSemantics = .unifiedPlan
		config.continualGatheringPolicy = .gatherContinually
		config.bundlePolicy = .maxBundle
		config.rtcpMuxPolicy = .require

		let constraints = RTCMediaConstraints(
			mandatoryConstraints: nil,
			optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
		)

		guard let pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
			Log.calls.error("Failed to create RTCPeerConnection")
			return
		}
		self.pc = pc

		// Локальный аудиотрек
		let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
		let audioSource = Self.factory.audioSource(with: audioConstraints)
		let audio = Self.factory.audioTrack(with: audioSource, trackId: "audio0")
		self.localAudioTrack = audio
		pc.add(audio, streamIds: ["stream0"])

		// Локальный видео-трек (только если видео-звонок)
		if activeCall.type == .video {
			setupLocalVideo(pc: pc)
		}

		// caller НЕ шлёт offer сразу — ждёт пока callee нажмёт "Принять"
		// (AppState вызовет beginNegotiation() при получении call_accepted),
		// иначе offer прилетит callee раньше чем тот создаст свой CallManager
		// и будет тихо отброшен.
		// callee — ждёт offer через handleRemoteSDP (буферизованный CallSignaling-ом
		// если успел прийти до attach).
	}

	/// Вызывается AppState'ом у caller'а после получения call_accepted.
	func beginNegotiation() async {
		guard activeCall.iAmCaller else { return }
		await makeOfferAndSend()
	}

	func stop() {
		signaling.detach(callId: activeCall.id)

		videoCapturer?.stopCapture()
		videoCapturer = nil

		pc?.close()
		pc = nil

		localAudioTrack = nil
		localVideoTrack = nil
		remoteVideoTrack = nil

		// Аудиосессию НЕ дезактивируем — CallKit сам пришлёт didDeactivate
		// после CXEndCallAction, и в нашем коллбэке мы снимем isAudioEnabled.
		let session = RTCAudioSession.sharedInstance()
		session.lockForConfiguration()
		session.isAudioEnabled = false
		session.unlockForConfiguration()
	}

	// MARK: – Контролы (привязываются к UI)

	func toggleMute() {
		activeCall.micMuted.toggle()
		localAudioTrack?.isEnabled = !activeCall.micMuted
	}

	/// Принудительно выставить состояние mute (вызывается CallKit'ом
	/// когда юзер крутит mute в системном UI / lock screen).
	func setMuted(_ muted: Bool) {
		guard activeCall.micMuted != muted else { return }
		activeCall.micMuted = muted
		localAudioTrack?.isEnabled = !muted
	}

	// MARK: – CallKit audio session callbacks

	/// CallKit активировал системную аудиосессию — теперь WebRTC может стартовать
	/// аудио-юнит. До этого момента ему нужно ждать, иначе будет молчанка.
	func didActivateAudioSession() {
		// WebRTC внутри сам подхватит активную сессию — нам ничего делать не надо
		// кроме как обновить флаги в RTCAudioSession чтобы он не дезактивировал её.
		RTCAudioSession.sharedInstance().audioSessionDidActivate(AVAudioSession.sharedInstance())
		RTCAudioSession.sharedInstance().isAudioEnabled = true
	}

	func didDeactivateAudioSession() {
		RTCAudioSession.sharedInstance().audioSessionDidDeactivate(AVAudioSession.sharedInstance())
		RTCAudioSession.sharedInstance().isAudioEnabled = false
	}

	func toggleCamera() {
		guard activeCall.type == .video else { return }
		activeCall.cameraOn.toggle()
		localVideoTrack?.isEnabled = activeCall.cameraOn
		if activeCall.cameraOn { startCapture() } else { videoCapturer?.stopCapture() }
	}

	func flipCamera() {
		activeCall.usingFrontCamera.toggle()
		startCapture()
	}

	func toggleSpeaker() {
		activeCall.speakerOn.toggle()
		let session = RTCAudioSession.sharedInstance()
		session.lockForConfiguration()
		defer { session.unlockForConfiguration() }
		try? session.overrideOutputAudioPort(activeCall.speakerOn ? .speaker : .none)
	}

	// MARK: – SDP / ICE — приём через сигналинг

	func handleRemoteSDP(kind: String, sdpString: String) async {
		Log.calls.debug("REMOTE SDP received: kind=\(kind), bytes=\(sdpString.count)")
		guard let pc else { Log.calls.error("remoteSDP: pc is nil"); return }
		let type: RTCSdpType = (kind == "offer") ? .offer : .answer
		let sdp = RTCSessionDescription(type: type, sdp: sdpString)
		do {
			try await Self.setRemote(pc: pc, sdp: sdp)
			hasRemoteDescription = true
			Log.calls.debug("setRemoteDescription OK, draining \(pendingRemoteIce.count) buffered ICE")
			for cand in pendingRemoteIce { Self.addCandidate(pc: pc, candidate: cand) }
			pendingRemoteIce.removeAll()

			if type == .offer {
				let answerConstraints = RTCMediaConstraints(
					mandatoryConstraints: [
						"OfferToReceiveAudio": "true",
						"OfferToReceiveVideo": activeCall.type == .video ? "true" : "false",
					],
					optionalConstraints: nil
				)
				let rawAnswer = try await Self.answer(pc: pc, constraints: answerConstraints)
				let finalSdp = (activeCall.type == .video) ? preferH264(in: rawAnswer.sdp) : rawAnswer.sdp
				let answer = RTCSessionDescription(type: rawAnswer.type, sdp: finalSdp)
				try await Self.setLocal(pc: pc, sdp: answer)
				await signaling.send(callId: activeCall.id, kind: "answer", payload: [
					"sdp": answer.sdp,
				])
			}
			// Negotiation теперь завершена — поднимаем битрейт видео-encoder'а
			tuneVideoBitrate()
		} catch {
			Log.calls.error("setRemote failed: \(String(describing: error))")
		}
	}

	func handleRemoteIce(payload: [String: Any]) async {
		// sdpMLineIndex может прилететь как Int / Int32 / NSNumber — нормализуем
		let mLineRaw: Int32?
		if let n = payload["sdpMLineIndex"] as? Int32 { mLineRaw = n }
		else if let n = payload["sdpMLineIndex"] as? Int { mLineRaw = Int32(n) }
		else if let n = payload["sdpMLineIndex"] as? NSNumber { mLineRaw = n.int32Value }
		else { mLineRaw = nil }

		guard
			let sdpMid = payload["sdpMid"] as? String,
			let sdpMLineIndex = mLineRaw,
			let sdp = payload["candidate"] as? String
		else {
			Log.calls.warning("REMOTE ICE: malformed payload \(payload)")
			return
		}
		let kind: String
		if sdp.contains(" typ host") { kind = "host" }
		else if sdp.contains(" typ srflx") { kind = "srflx" }
		else if sdp.contains(" typ relay") { kind = "relay" }
		else { kind = "other" }
		Log.calls.debug("REMOTE ICE received: \(kind) (buffered=\(!hasRemoteDescription))")
		let cand = RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
		if hasRemoteDescription, let pc {
			Self.addCandidate(pc: pc, candidate: cand)
		} else {
			pendingRemoteIce.append(cand)
		}
	}

	// MARK: – Render-вьюхи (для SwiftUI)

	func ensureRenderers() {
		if localRenderer == nil {
			let v = RTCMTLVideoView()
			v.videoContentMode = .scaleAspectFill
			localRenderer = v
			localVideoTrack?.add(v)
		}
		if remoteRenderer == nil {
			let v = RTCMTLVideoView()
			v.videoContentMode = .scaleAspectFill
			remoteRenderer = v
			remoteVideoTrack?.add(v)
		}
	}

	// MARK: – Private

	private func makeOfferAndSend() async {
		guard let pc else { return }
		let constraints = RTCMediaConstraints(
			mandatoryConstraints: [
				"OfferToReceiveAudio": "true",
				"OfferToReceiveVideo": activeCall.type == .video ? "true" : "false",
			],
			optionalConstraints: nil
		)
		do {
			let rawOffer = try await Self.offer(pc: pc, constraints: constraints)
			// Для видео — переставляем H.264 в приоритет (аппаратный кодек iOS)
			let finalSdp = (activeCall.type == .video) ? preferH264(in: rawOffer.sdp) : rawOffer.sdp
			let offer = RTCSessionDescription(type: rawOffer.type, sdp: finalSdp)
			try await Self.setLocal(pc: pc, sdp: offer)
			await signaling.send(callId: activeCall.id, kind: "offer", payload: ["sdp": offer.sdp])
		} catch {
			Log.calls.error("makeOffer failed: \(String(describing: error))")
		}
	}

	// MARK: – Async-обёртки над callback-API WebRTC SDK

	private static func offer(pc: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
		try await withCheckedThrowingContinuation { cont in
			pc.offer(for: constraints) { sdp, err in
				if let err { cont.resume(throwing: err) }
				else if let sdp { cont.resume(returning: sdp) }
				else { cont.resume(throwing: NSError(domain: "siberia.calls", code: -1)) }
			}
		}
	}

	private static func answer(pc: RTCPeerConnection, constraints: RTCMediaConstraints) async throws -> RTCSessionDescription {
		try await withCheckedThrowingContinuation { cont in
			pc.answer(for: constraints) { sdp, err in
				if let err { cont.resume(throwing: err) }
				else if let sdp { cont.resume(returning: sdp) }
				else { cont.resume(throwing: NSError(domain: "siberia.calls", code: -2)) }
			}
		}
	}

	private static func setLocal(pc: RTCPeerConnection, sdp: RTCSessionDescription) async throws {
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			pc.setLocalDescription(sdp) { err in
				if let err { cont.resume(throwing: err) } else { cont.resume() }
			}
		}
	}

	private static func setRemote(pc: RTCPeerConnection, sdp: RTCSessionDescription) async throws {
		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			pc.setRemoteDescription(sdp) { err in
				if let err { cont.resume(throwing: err) } else { cont.resume() }
			}
		}
	}

	private static func addCandidate(pc: RTCPeerConnection, candidate: RTCIceCandidate) {
		pc.add(candidate) { err in
			if let err { Log.calls.error("add ICE failed: \(String(describing: err))") }
		}
	}

	private func setupLocalVideo(pc: RTCPeerConnection) {
		let source = Self.factory.videoSource()
		let track = Self.factory.videoTrack(with: source, trackId: "video0")
		self.localVideoTrack = track
		pc.add(track, streamIds: ["stream0"])

		let capturer = RTCCameraVideoCapturer(delegate: source)
		self.videoCapturer = capturer
		startCapture()
	}

	private func startCapture() {
		guard let capturer = videoCapturer else { return }
		let position: AVCaptureDevice.Position = activeCall.usingFrontCamera ? .front : .back
		let devices = RTCCameraVideoCapturer.captureDevices()
		guard let device = devices.first(where: { $0.position == position }) ?? devices.first else { return }

		// Берём НАИБОЛЬШИЙ формат до 1920x1080 (1080p потолок). Если камера не
		// поддерживает — спустится до 720p или того что есть.
		let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
		let pixelArea: (AVCaptureDevice.Format) -> Int = { fmt in
			let dim = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
			return Int(dim.width) * Int(dim.height)
		}
		let target = 1920 * 1080
		let format = formats
			.filter { pixelArea($0) <= target }
			.max(by: { pixelArea($0) < pixelArea($1) })
			?? formats.first
		guard let format else { return }

		// Капаем 30 fps — 60fps только удвоит битрейт и нагрев, для видеосвязи бесполезно.
		let supportedMax = format.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30
		let fps = Int(min(30, supportedMax))

		capturer.stopCapture { [weak capturer] in
			capturer?.startCapture(with: device, format: format, fps: fps)
		}
	}

	/// Поднимаем кэп битрейта видео-encoder'а WebRTC + degradation policy.
	/// Без этого SDK ставит дефолт ~500-700 kbps и картинка получается мыльной.
	private func tuneVideoBitrate() {
		guard let pc, activeCall.type == .video else { return }
		for sender in pc.senders where sender.track is RTCVideoTrack {
			let params = sender.parameters
			// При просадке сети — режем FPS, не разрешение (текст/лица остаются чёткими)
			params.degradationPreference = NSNumber(value: RTCDegradationPreference.maintainResolution.rawValue)
			for enc in params.encodings {
				enc.maxBitrateBps = NSNumber(value: 4_000_000)  // 4 Mbps cap для 1080p
				enc.minBitrateBps = NSNumber(value: 1_200_000)  // 1.2 Mbps floor
				enc.maxFramerate  = NSNumber(value: 30)
				enc.isActive      = true
			}
			sender.parameters = params
		}
	}

	/// Переставляет H.264 в начало списка кодеков для m=video в SDP.
	/// iOS имеет аппаратный H.264-encoder/decoder — он эффективнее VP8 на ~30%
	/// при той же битрейте (картинка чище, CPU/батарея ниже).
	private func preferH264(in sdp: String) -> String {
		let separator = sdp.contains("\r\n") ? "\r\n" : "\n"
		let lines = sdp.components(separatedBy: separator)

		// 1) Собираем PT кодеков H.264 из a=rtpmap:N H264/90000
		var h264PTs: [String] = []
		for line in lines where line.hasPrefix("a=rtpmap:") && line.contains(" H264/") {
			// "a=rtpmap:127 H264/90000"
			let trimmed = String(line.dropFirst("a=rtpmap:".count))
			if let space = trimmed.firstIndex(of: " ") {
				h264PTs.append(String(trimmed[..<space]))
			}
		}
		guard !h264PTs.isEmpty else { return sdp }

		// 2) Перепиcываем m=video строку: ставим H.264 PT первыми
		var result: [String] = []
		for line in lines {
			if line.hasPrefix("m=video ") {
				let parts = line.split(separator: " ").map(String.init)
				guard parts.count > 3 else { result.append(line); continue }
				let header  = parts.prefix(3).joined(separator: " ")  // "m=video 9 UDP/TLS/RTP/SAVPF"
				let oldPTs  = Array(parts.dropFirst(3))
				let newPTs  = h264PTs + oldPTs.filter { !h264PTs.contains($0) }
				result.append("\(header) \(newPTs.joined(separator: " "))")
			} else {
				result.append(line)
			}
		}
		return result.joined(separator: separator)
	}

	private func configureAudioSession() {
		// CallKit владеет аудиосессией — он сам её активирует через didActivate.
		// Наша задача — только настроить параметры (category/mode/options) и
		// перевести WebRTC в manual-audio режим, чтобы он не дёргал setActive
		// в обход CallKit.
		let isVideo = (activeCall.type == .video)
		let rtcConfig = RTCAudioSessionConfiguration.webRTC()
		rtcConfig.category = AVAudioSession.Category.playAndRecord.rawValue
		rtcConfig.mode = (isVideo
			? AVAudioSession.Mode.videoChat.rawValue
			: AVAudioSession.Mode.voiceChat.rawValue)
		rtcConfig.categoryOptions = isVideo
			? [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
			: [.allowBluetooth, .allowBluetoothA2DP]
		RTCAudioSessionConfiguration.setWebRTC(rtcConfig)

		let session = RTCAudioSession.sharedInstance()
		session.lockForConfiguration()
		defer { session.unlockForConfiguration() }
		// useManualAudio + isAudioEnabled=false → ждём CallKit'овский didActivate
		session.useManualAudio = true
		session.isAudioEnabled = false
		do {
			try session.setConfiguration(rtcConfig)
			if isVideo {
				try session.overrideOutputAudioPort(.speaker)
				activeCall.speakerOn = true
			} else {
				try session.overrideOutputAudioPort(.none)
				activeCall.speakerOn = false
			}
		} catch {
			Log.calls.error("RTCAudioSession config failed: \(String(describing: error))")
		}
	}
}

// MARK: – RTCPeerConnectionDelegate

extension CallManager: RTCPeerConnectionDelegate {

	nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
		let stateName: String
		switch newState {
		case .new: stateName = "new"
		case .checking: stateName = "checking"
		case .connected: stateName = "connected"
		case .completed: stateName = "completed"
		case .failed: stateName = "failed"
		case .disconnected: stateName = "disconnected"
		case .closed: stateName = "closed"
		case .count: stateName = "count"
		@unknown default: stateName = "unknown"
		}
		Log.calls.debug("ICE state: \(stateName)")
		Task { @MainActor in
			switch newState {
			case .checking:
				if activeCall.phase != .active { activeCall.phase = .connecting }
			case .connected, .completed:
				if activeCall.phase != .active {
					activeCall.phase = .active
					if activeCall.connectedAt == nil { activeCall.connectedAt = Date() }
				}
			case .failed, .disconnected, .closed:
				if newState == .failed || newState == .closed {
					activeCall.phase = .ended
				}
			default: break
			}
		}
	}

	nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
		// Берём тип кандидата (host / srflx / relay) из SDP для диагностики
		let kind: String
		if candidate.sdp.contains(" typ host") { kind = "host" }
		else if candidate.sdp.contains(" typ srflx") { kind = "srflx" }
		else if candidate.sdp.contains(" typ relay") { kind = "relay" }
		else { kind = "other" }
		Log.calls.debug("LOCAL ICE generated: \(kind) — \(candidate.sdp.prefix(80))…")
		Task { @MainActor in
			await signaling.send(callId: activeCall.id, kind: "ice", payload: [
				"candidate": candidate.sdp,
				"sdpMid": candidate.sdpMid ?? "",
				"sdpMLineIndex": candidate.sdpMLineIndex,
			])
		}
	}

	nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
		let name: String
		switch newState {
		case .new: name = "new"
		case .gathering: name = "gathering"
		case .complete: name = "complete"
		@unknown default: name = "unknown"
		}
		Log.calls.debug("ICE gathering: \(name)")
	}

	nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
		// Unified-Plan: новые входящие треки приходят сюда.
		guard let track = rtpReceiver.track else { return }
		if let videoTrack = track as? RTCVideoTrack {
			Task { @MainActor in
				self.remoteVideoTrack = videoTrack
				self.activeCall.remoteHasVideo = true
				if let renderer = self.remoteRenderer {
					videoTrack.add(renderer)
				}
			}
		}
	}

	// Остальные методы делегата — не используем, но обязаны быть
	nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
	nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
	nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
	nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
	nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
	nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
