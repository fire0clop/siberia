import AVKit
import SwiftUI

struct FullscreenVideoView: View {
	let url: URL
	@Environment(\.dismiss) private var dismiss

	@State private var player: AVPlayer?

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			if let player {
				VideoPlayer(player: player)
					.ignoresSafeArea()
			} else {
				ProgressView().tint(.white)
			}

			// Close
			VStack {
				HStack {
					Button { dismiss() } label: {
						Image(systemName: "xmark")
							.font(.system(size: 16, weight: .semibold))
							.foregroundStyle(.white)
							.frame(width: 36, height: 36)
							.background(Circle().fill(.black.opacity(0.5)))
					}
					.padding(16)
					Spacer()
				}
				Spacer()
			}
		}
		.statusBarHidden()
		.onAppear {
			let p = AVPlayer(url: url)
			player = p
			p.play()
		}
		.onDisappear {
			player?.pause()
			player = nil
		}
	}
}
