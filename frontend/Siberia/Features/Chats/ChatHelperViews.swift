import SwiftUI

// MARK: – Voice waveform bars

struct VoiceWaveformView: View {
	let bars: [Float]
	var progress: Double = 0      // 0…1 — filled portion
	var tint: Color = .white
	var background: Color = Color.white.opacity(0.35)

	var body: some View {
		HStack(alignment: .center, spacing: 2) {
			ForEach(Array(bars.enumerated()), id: \.offset) { idx, level in
				let pos = Double(idx) / Double(max(1, bars.count - 1))
				Capsule()
					.fill(pos <= progress ? tint : background)
					.frame(width: 2.5, height: max(3, CGFloat(level) * 26 + 3))
			}
		}
	}
}

// MARK: – Online pulse indicator

struct OnlinePulse: View {
	@State private var pulse = false
	private let green = Color(red: 0.22, green: 0.78, blue: 0.45)

	var body: some View {
		ZStack {
			Circle().fill(green.opacity(0.3))
				.scaleEffect(pulse ? 1.8 : 1)
				.opacity(pulse ? 0 : 0.6)
				.animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: pulse)
			Circle().fill(green)
				.overlay(Circle().stroke(.white, lineWidth: 2))
		}
		.onAppear { pulse = true }
	}
}

// MARK: – Typing dots

struct TypingDots: View {
	@State private var phase = 0
	@State private var timer: Timer?
	var body: some View {
		HStack(spacing: 2) {
			ForEach(0..<3, id: \.self) { i in
				Circle().fill(ChatDetailView.accent)
					.frame(width: 4, height: 4)
					.scaleEffect(phase == i ? 1.5 : 0.8)
					.animation(.easeInOut(duration: 0.4).delay(Double(i) * 0.12), value: phase)
			}
		}
		.onAppear {
			timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
				phase = (phase + 1) % 3
			}
		}
		.onDisappear {
			timer?.invalidate()
			timer = nil
		}
	}
}

// MARK: – Blinking recording dot

struct BlinkingDot: View {
	@State private var on = true
	var body: some View {
		Circle().fill(Color.red).frame(width: 8, height: 8)
			.opacity(on ? 1 : 0.3)
			.onAppear {
				withAnimation(.easeInOut(duration: 0.5).repeatForever()) { on.toggle() }
			}
	}
}

// MARK: – Upload progress bar

struct UploadProgressBar: View {
	@State private var offset: CGFloat = -300
	var body: some View {
		GeometryReader { geo in
			ZStack(alignment: .leading) {
				Color(.systemFill)
				ChatDetailView.accent.opacity(0.75)
					.frame(width: geo.size.width * 0.4)
					.offset(x: offset)
					.onAppear {
						withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
							offset = geo.size.width + 120
						}
					}
			}
		}
		.frame(height: 2)
		.clipShape(Rectangle())
	}
}

// MARK: – Message skeleton (loading state)

struct MessageSkeletonView: View {
	private let rows: [(Bool, CGFloat)] = [
		(false, 150), (true, 190), (false, 110), (true, 230), (false, 170), (true, 120)
	]
	@State private var shimmer = false
	var body: some View {
		VStack(spacing: 10) {
			ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
				HStack {
					if row.0 { Spacer(minLength: 52) }
					RoundedRectangle(cornerRadius: 16)
						.fill(Color.gray.opacity(shimmer ? 0.18 : 0.09))
						.frame(width: row.1, height: 40)
						.animation(.easeInOut(duration: 1.0).repeatForever().delay(Double(i) * 0.1), value: shimmer)
					if !row.0 { Spacer(minLength: 52) }
				}
				.padding(.horizontal, 10)
			}
		}
		.onAppear { shimmer = true }
	}
}
