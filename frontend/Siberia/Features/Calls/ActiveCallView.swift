import SwiftUI
import WebRTC

// MARK: – ActiveCallView

struct ActiveCallView: View {

	@ObservedObject var call: ActiveCall
	let manager: CallManager
	let onEnd: () -> Void

	@State private var tick = Date()
	@State private var controlsVisible = true
	@State private var hideControlsTask: Task<Void, Never>?

	private let ac1 = Color(red: 0.44, green: 0.30, blue: 0.97)
	private let ac2 = Color(red: 0.03, green: 0.70, blue: 0.85)

	var body: some View {
		ZStack {
			// Фон: видео-стрим пира если есть, иначе аврора
			if call.type == .video && call.remoteHasVideo, let remote = manager.remoteRenderer {
				RTCVideoViewRepresentable(view: remote)
					.ignoresSafeArea()
					.background(Color.black)
			} else {
				AudioCallAurora(time: tick.timeIntervalSinceReferenceDate)
				audioModeForeground
			}

			// PiP с локальной камерой (правый верх)
			if call.type == .video && call.cameraOn, let local = manager.localRenderer {
				VStack {
					HStack {
						Spacer()
						RTCVideoViewRepresentable(view: local)
							.frame(width: 110, height: 150)
							.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
							.overlay(
								RoundedRectangle(cornerRadius: 14, style: .continuous)
									.stroke(.white.opacity(0.20), lineWidth: 1)
							)
							.shadow(color: .black.opacity(0.5), radius: 10, y: 4)
							.padding(.trailing, 16)
							.padding(.top, 60)
					}
					Spacer()
				}
				.transition(.opacity)
			}

			// Top bar — имя + статус + таймер
			if controlsVisible {
				VStack(spacing: 8) {
					Text(call.peer.nickname)
						.font(.system(size: 22, weight: .bold))
						.foregroundStyle(.white)
						.shadow(color: .black.opacity(0.6), radius: 4)
					Text(statusText)
						.font(.system(size: 14))
						.foregroundStyle(.white.opacity(0.75))
						.shadow(color: .black.opacity(0.6), radius: 4)
				}
				.padding(.top, 56)
				.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
				.transition(.opacity)
			}

			// Bottom — кнопки управления
			if controlsVisible {
				VStack {
					Spacer()
					controlsBar
						.padding(.horizontal, 24)
						.padding(.bottom, 36)
				}
				.transition(.opacity)
			}
		}
		.preferredColorScheme(.dark)
		.statusBarHidden(true)
		.contentShape(Rectangle())
		.onTapGesture {
			withAnimation(.easeInOut(duration: 0.22)) { controlsVisible.toggle() }
			scheduleHide()
		}
		.onAppear {
			manager.ensureRenderers()
			startTicker()
			scheduleHide()
		}
		.onDisappear { hideControlsTask?.cancel() }
	}

	// MARK: – Audio mode foreground (аватар + статус)

	private var audioModeForeground: some View {
		VStack(spacing: 28) {
			Spacer().frame(height: 140)
			ZStack {
				Circle()
					.fill(ac1.opacity(0.40))
					.frame(width: 200, height: 200)
					.blur(radius: 36)
				Circle()
					.fill(LinearGradient(colors: [ac1, ac2],
										 startPoint: .topLeading, endPoint: .bottomTrailing))
					.frame(width: 156, height: 156)
				if let urlStr = call.peer.avatarUrl, let url = URL(string: urlStr) {
					AsyncImage(url: url) { phase in
						if case .success(let img) = phase {
							img.resizable().scaledToFill()
								.frame(width: 148, height: 148).clipShape(Circle())
						} else { audioInitials }
					}
				} else { audioInitials }
			}
			Spacer()
		}
	}

	private var audioInitials: some View {
		Text(String(call.peer.nickname.prefix(1)).uppercased())
			.font(.system(size: 60, weight: .bold))
			.foregroundStyle(.white)
	}

	// MARK: – Controls bar

	private var controlsBar: some View {
		HStack(spacing: 0) {
			ControlButton(
				icon: call.micMuted ? "mic.slash.fill" : "mic.fill",
				active: call.micMuted,
				label: call.micMuted ? "Включить" : "Mute"
			) { manager.toggleMute() }

			if call.type == .video {
				ControlButton(
					icon: call.cameraOn ? "video.fill" : "video.slash.fill",
					active: !call.cameraOn,
					label: call.cameraOn ? "Камера" : "Включить"
				) { manager.toggleCamera() }

				ControlButton(
					icon: "arrow.triangle.2.circlepath.camera.fill",
					active: false,
					label: "Перекл."
				) { manager.flipCamera() }
			} else {
				ControlButton(
					icon: call.speakerOn ? "speaker.wave.3.fill" : "speaker.wave.1.fill",
					active: call.speakerOn,
					label: "Динамик"
				) { manager.toggleSpeaker() }
			}

			endButton
		}
		.padding(.vertical, 14)
		.padding(.horizontal, 16)
		.background(.ultraThinMaterial.opacity(0.7))
		.background(Color.black.opacity(0.18))
		.clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 28, style: .continuous)
				.stroke(.white.opacity(0.10), lineWidth: 1)
		)
	}

	private var endButton: some View {
		Button {
			UIImpactFeedbackGenerator(style: .medium).impactOccurred()
			onEnd()
		} label: {
			VStack(spacing: 6) {
				ZStack {
					Circle().fill(Color.red)
						.frame(width: 54, height: 54)
						.shadow(color: .red.opacity(0.55), radius: 14, y: 4)
					Image(systemName: "phone.down.fill")
						.font(.system(size: 22, weight: .semibold))
						.foregroundStyle(.white)
				}
				Text("Завершить")
					.font(.system(size: 11))
					.foregroundStyle(.white.opacity(0.65))
			}
			.frame(maxWidth: .infinity)
		}
		.buttonStyle(.plain)
	}

	// MARK: – Status text + timer

	private var statusText: String {
		switch call.phase {
		case .dialing:    return "Вызов…"
		case .ringing:    return "Входящий"
		case .connecting: return "Соединение…"
		case .active:     return durationString
		case .ended:      return "Звонок завершён"
		}
	}

	private var durationString: String {
		guard let start = call.connectedAt else { return "00:00" }
		let s = Int(tick.timeIntervalSince(start))
		let m = s / 60, sec = s % 60
		return String(format: "%02d:%02d", m, sec)
	}

	private func startTicker() {
		Task { @MainActor in
			while call.phase != .ended {
				tick = Date()
				try? await Task.sleep(nanoseconds: 500_000_000)
			}
		}
	}

	private func scheduleHide() {
		hideControlsTask?.cancel()
		guard call.phase == .active, call.type == .video else { return }
		hideControlsTask = Task { @MainActor in
			try? await Task.sleep(nanoseconds: 4_500_000_000)
			withAnimation(.easeInOut(duration: 0.22)) { controlsVisible = false }
		}
	}
}

// MARK: – Control button

private struct ControlButton: View {
	let icon: String
	let active: Bool
	let label: String
	let action: () -> Void
	@State private var pressing = false

	var body: some View {
		Button {
			UIImpactFeedbackGenerator(style: .soft).impactOccurred()
			action()
		} label: {
			VStack(spacing: 6) {
				ZStack {
					Circle()
						.fill(active ? Color.white : Color.white.opacity(0.10))
						.frame(width: 54, height: 54)
						.overlay(Circle().stroke(.white.opacity(0.16), lineWidth: 1))
					Image(systemName: icon)
						.font(.system(size: 21, weight: .medium))
						.foregroundStyle(active ? Color.black : Color.white)
				}
				Text(label)
					.font(.system(size: 11))
					.foregroundStyle(.white.opacity(0.65))
			}
			.scaleEffect(pressing ? 0.92 : 1)
			.frame(maxWidth: .infinity)
		}
		.buttonStyle(.plain)
		.animation(.easeInOut(duration: 0.12), value: pressing)
		.simultaneousGesture(
			DragGesture(minimumDistance: 0)
				.onChanged { _ in pressing = true }
				.onEnded   { _ in pressing = false }
		)
	}
}

// MARK: – Аврора для audio-режима

private struct AudioCallAurora: View {
	let time: Double
	var body: some View {
		GeometryReader { geo in
			let w = geo.size.width, h = geo.size.height
			ZStack {
				Color(red: 0.04, green: 0.03, blue: 0.12).ignoresSafeArea()
				orb(x: w*(0.32+0.20*sin(time*0.12)), y: h*(0.30+0.18*cos(time*0.10)),
					r: 520, c: Color(red:0.24,green:0.30,blue:0.98))
				orb(x: w*(0.70+0.16*sin(time*0.09+1.4)), y: h*(0.66+0.20*cos(time*0.14+2.0)),
					r: 460, c: Color(red:0.52,green:0.13,blue:0.90))
			}
		}
		.blur(radius: 60)
		.ignoresSafeArea()
	}
	private func orb(x: CGFloat, y: CGFloat, r: CGFloat, c: Color) -> some View {
		RadialGradient(colors: [c.opacity(0.70), .clear], center: .center,
					   startRadius: 0, endRadius: r/2)
			.frame(width: r, height: r)
			.position(x: x, y: y)
			.blendMode(.screen)
	}
}

// MARK: – UIKit-обёртка для RTCMTLVideoView

struct RTCVideoViewRepresentable: UIViewRepresentable {
	let view: RTCMTLVideoView
	func makeUIView(context: Context) -> RTCMTLVideoView { view }
	func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
}
