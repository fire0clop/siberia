import SwiftUI

struct FullscreenImageView: View {

	let url: URL
	@Environment(\.dismiss) private var dismiss

	@State private var scale: CGFloat = 1
	@State private var offset: CGSize = .zero
	@State private var lastScale: CGFloat = 1
	@State private var lastOffset: CGSize = .zero

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			AsyncImage(url: url) { phase in
				switch phase {
				case .success(let image):
					image
						.resizable()
						.scaledToFit()
						.scaleEffect(scale)
						.offset(offset)
						.gesture(magnification)
						.gesture(drag)
						.onTapGesture(count: 2) { doubleTap() }
				case .failure:
					Image(systemName: "photo")
						.font(.largeTitle)
						.foregroundStyle(.secondary)
				default:
					ProgressView()
				}
			}
		}
		.overlay(alignment: .topTrailing) {
			Button { dismiss() } label: {
				Image(systemName: "xmark.circle.fill")
					.font(.title2)
					.foregroundStyle(.white.opacity(0.8))
					.padding(16)
			}
		}
		.statusBarHidden()
	}

	private var magnification: some Gesture {
		MagnificationGesture()
			.onChanged { value in
				scale = max(1, min(lastScale * value, 5))
			}
			.onEnded { value in
				lastScale = scale
				if scale < 1.05 { resetTransform() }
			}
	}

	private var drag: some Gesture {
		DragGesture()
			.onChanged { value in
				offset = CGSize(
					width: lastOffset.width + value.translation.width,
					height: lastOffset.height + value.translation.height
				)
			}
			.onEnded { value in
				lastOffset = offset
				// Dismiss if dragged far down while not zoomed
				if scale <= 1.05 && value.translation.height > 120 {
					dismiss()
				}
			}
	}

	private func doubleTap() {
		withAnimation(.spring(response: 0.3)) {
			if scale > 1.5 { resetTransform() } else { scale = 2.5; lastScale = 2.5 }
		}
	}

	private func resetTransform() {
		withAnimation(.spring(response: 0.3)) {
			scale = 1; lastScale = 1
			offset = .zero; lastOffset = .zero
		}
	}
}
