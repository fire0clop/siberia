import SwiftUI
import AVFoundation
import UIKit

struct IncomingCallView: View {
	let info: IncomingCallInfo
	let onAccept: () -> Void
	let onDecline: () -> Void

	@State private var ringScale: CGFloat = 1.0
	@State private var aurora: Double = 0

	private let ac1 = Color(red: 0.44, green: 0.30, blue: 0.97)
	private let ac2 = Color(red: 0.03, green: 0.70, blue: 0.85)

	var body: some View {
		ZStack {
			// Фон — аврора как в auth
			TimelineView(.animation) { tl in
				let t = tl.date.timeIntervalSinceReferenceDate
				IncomingCallAurora(time: t)
			}

			VStack(spacing: 0) {
				Spacer().frame(height: 60)

				// Тип звонка
				Text(info.call.type == .video ? "Видео-звонок" : "Звонок")
					.font(.system(size: 14, weight: .medium))
					.tracking(2)
					.foregroundStyle(.white.opacity(0.55))
					.textCase(.uppercase)

				Spacer().frame(height: 36)

				// Аватар с пульсирующими кольцами
				ZStack {
					ForEach(0..<3) { i in
						Circle()
							.stroke(.white.opacity(0.18 - Double(i) * 0.05), lineWidth: 1.5)
							.frame(width: 160 + CGFloat(i) * 40, height: 160 + CGFloat(i) * 40)
							.scaleEffect(ringScale)
							.opacity(2 - ringScale)
					}
					avatarCircle
				}
				.frame(height: 260)

				Spacer().frame(height: 24)

				// Имя
				Text(info.caller.nickname)
					.font(.system(size: 30, weight: .bold, design: .rounded))
					.foregroundStyle(.white)

				Text("звонит вам…")
					.font(.system(size: 16))
					.foregroundStyle(.white.opacity(0.55))
					.padding(.top, 6)

				Spacer()

				// Кнопки
				HStack(spacing: 80) {
					CallActionButton(
						icon: "phone.down.fill",
						color: .red,
						label: "Отклонить",
						action: onDecline
					)
					CallActionButton(
						icon: info.call.type == .video ? "video.fill" : "phone.fill",
						color: .green,
						label: "Принять",
						action: onAccept
					)
				}
				.padding(.bottom, 56)
			}
		}
		.preferredColorScheme(.dark)
		.onAppear {
			withAnimation(.easeOut(duration: 2.0).repeatForever(autoreverses: false)) {
				ringScale = 2.0
			}
			startHaptics()
		}
		.onDisappear { stopHaptics() }
	}

	private var avatarCircle: some View {
		ZStack {
			Circle()
				.fill(LinearGradient(colors: [ac1, ac2],
									 startPoint: .topLeading, endPoint: .bottomTrailing))
				.frame(width: 132, height: 132)
				.shadow(color: ac1.opacity(0.6), radius: 30, y: 8)

			if let urlStr = info.caller.avatarUrl, let url = URL(string: urlStr) {
				AsyncImage(url: url) { phase in
					if case .success(let img) = phase {
						img.resizable().scaledToFill()
							.frame(width: 124, height: 124)
							.clipShape(Circle())
					} else { initialsText }
				}
			} else {
				initialsText
			}
		}
	}

	private var initialsText: some View {
		Text(String(info.caller.nickname.prefix(1)).uppercased())
			.font(.system(size: 48, weight: .bold))
			.foregroundStyle(.white)
	}

	// MARK: – Haptics + ring vibration

	@State private var hapticTimer: Timer?
	private func startHaptics() {
		let gen = UIImpactFeedbackGenerator(style: .heavy)
		gen.prepare()
		gen.impactOccurred()
		hapticTimer?.invalidate()
		hapticTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
			AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
			DispatchQueue.main.async { gen.impactOccurred() }
		}
	}
	private func stopHaptics() {
		hapticTimer?.invalidate()
		hapticTimer = nil
	}
}

// MARK: – Аврора для входящего

private struct IncomingCallAurora: View {
	let time: Double
	var body: some View {
		GeometryReader { geo in
			let w = geo.size.width, h = geo.size.height
			ZStack {
				Color(red: 0.04, green: 0.03, blue: 0.12).ignoresSafeArea()
				orb(x: w*(0.30+0.20*sin(time*0.12)), y: h*(0.30+0.18*cos(time*0.10)),
					r: 520, c: Color(red:0.24,green:0.30,blue:0.98))
				orb(x: w*(0.72+0.16*sin(time*0.09+1.4)), y: h*(0.62+0.20*cos(time*0.14+2.0)),
					r: 460, c: Color(red:0.52,green:0.13,blue:0.90))
				orb(x: w*(0.55+0.22*cos(time*0.20+0.8)), y: h*(0.18+0.16*sin(time*0.15+3.2)),
					r: 360, c: Color(red:0.03,green:0.70,blue:0.85))
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

// MARK: – Большая круглая кнопка

struct CallActionButton: View {
	let icon: String
	let color: Color
	let label: String
	let action: () -> Void
	@State private var pressing = false

	var body: some View {
		VStack(spacing: 8) {
			Button {
				UIImpactFeedbackGenerator(style: .medium).impactOccurred()
				action()
			} label: {
				ZStack {
					Circle()
						.fill(color)
						.frame(width: 74, height: 74)
						.shadow(color: color.opacity(0.55), radius: 18, y: 6)
					Image(systemName: icon)
						.font(.system(size: 28, weight: .semibold))
						.foregroundStyle(.white)
				}
				.scaleEffect(pressing ? 0.92 : 1)
			}
			.buttonStyle(.plain)
			.animation(.easeInOut(duration: 0.12), value: pressing)
			.simultaneousGesture(
				DragGesture(minimumDistance: 0)
					.onChanged { _ in pressing = true }
					.onEnded   { _ in pressing = false }
			)

			Text(label)
				.font(.system(size: 13))
				.foregroundStyle(.white.opacity(0.6))
		}
	}
}
