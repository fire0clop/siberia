import AVKit
import SwiftUI

// MARK: – Gallery entry point

struct MediaGalleryView: View {
	let items: [GalleryMediaItem]
	@State var currentIndex: Int
	@ObservedObject var vm: ChatDetailViewModel

	@Environment(\.dismiss) private var dismiss

	// Background / dismiss
	@State private var bgOpacity: Double = 1
	@State private var dismissY: CGFloat = 0

	// Paging
	@State private var pageDragX: CGFloat = 0
	@State private var isDraggingVertically = false

	// Zoom state (read from current page)
	@State private var isAnyPageZoomed = false

	// Zoomed-pan state (managed here, passed down as binding)
	@State private var panOffset: CGSize = .zero
	@State private var lastPanOffset: CGSize = .zero

	init(items: [GalleryMediaItem], startIndex: Int, vm: ChatDetailViewModel) {
		self.items = items
		self._currentIndex = State(initialValue: min(startIndex, max(0, items.count - 1)))
		self.vm = vm
	}

	var body: some View {
		ZStack {
			Color.black.opacity(bgOpacity).ignoresSafeArea()

			GeometryReader { geo in
				let w = geo.size.width
				HStack(spacing: 0) {
					ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
						GalleryPage(
							item: item,
							pageIndex: idx,
							currentIndex: $currentIndex,
							vm: vm,
							isZoomed: $isAnyPageZoomed,
							panOffset: idx == currentIndex ? panOffset : .zero
						)
						.frame(width: w)
					}
				}
				.frame(width: w * CGFloat(items.count), alignment: .leading)
				.offset(x: -CGFloat(currentIndex) * w + pageDragX)
				.gesture(masterGesture(pageWidth: w))
			}
			.clipped()

			// Top bar
			topBar

			// Dot indicator
			VStack {
				Spacer()
				if items.count > 1 && items.count <= 12 {
					HStack(spacing: 6) {
						ForEach(0..<items.count, id: \.self) { i in
							Circle()
								.fill(i == currentIndex ? Color.white : Color.white.opacity(0.4))
								.frame(width: i == currentIndex ? 7 : 5,
								       height: i == currentIndex ? 7 : 5)
								.animation(.spring(response: 0.25), value: currentIndex)
						}
					}
					.padding(.bottom, 24)
				}
			}
		}
		.offset(y: dismissY)
		.statusBarHidden()
		.onChange(of: currentIndex) { _, _ in
			panOffset = .zero
			lastPanOffset = .zero
		}
	}

	// MARK: – Master gesture (paging + dismiss + zoomed pan — all in one)

	private func masterGesture(pageWidth: CGFloat) -> some Gesture {
		DragGesture(minimumDistance: 10)
			.onChanged { v in
				let h = v.translation.width
				let vert = v.translation.height

				// When zoomed: pan the current image
				if isAnyPageZoomed {
					panOffset = CGSize(
						width:  lastPanOffset.width  + h,
						height: lastPanOffset.height + vert
					)
					return
				}

				let isH = abs(h) > abs(vert) * 1.1

				if isH && !isDraggingVertically {
					pageDragX = h
				} else if !isH && vert > 0 {
					isDraggingVertically = true
				}

				if isDraggingVertically {
					dismissY = vert * 0.6
					bgOpacity = max(0.3, 1.0 - vert / 380.0)
				}
			}
			.onEnded { v in
				// When zoomed: commit pan
				if isAnyPageZoomed {
					lastPanOffset = panOffset
					return
				}

				if isDraggingVertically {
					if v.translation.height > 80 || v.velocity.height > 500 {
						withAnimation(.easeOut(duration: 0.2)) {
							dismissY = 700; bgOpacity = 0
						}
						DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) { dismiss() }
					} else {
						withAnimation(.spring(response: 0.3)) {
							dismissY = 0; bgOpacity = 1
						}
					}
				} else {
					withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
						if v.translation.width < -(pageWidth * 0.25) && currentIndex < items.count - 1 {
							currentIndex += 1
						} else if v.translation.width > (pageWidth * 0.25) && currentIndex > 0 {
							currentIndex -= 1
						}
						pageDragX = 0
					}
				}
				isDraggingVertically = false
			}
	}

	// MARK: – Top bar

	private var topBar: some View {
		VStack {
			HStack {
				Button { dismiss() } label: {
					Image(systemName: "xmark")
						.font(.system(size: 16, weight: .semibold))
						.foregroundStyle(.white)
						.frame(width: 36, height: 36)
						.background(Circle().fill(.black.opacity(0.45)))
				}
				.padding(.leading, 16)
				Spacer()
				if items.count > 1 {
					Text("\(currentIndex + 1) / \(items.count)")
						.font(.subheadline.weight(.medium))
						.foregroundStyle(.white)
				}
				Spacer()
				if !items[currentIndex].isVideo,
				   let urlStr = vm.mediaURLCache[items[currentIndex].id],
				   let url = URL(string: urlStr) {
					ShareLink(item: url) {
						Image(systemName: "square.and.arrow.up")
							.font(.system(size: 16, weight: .semibold))
							.foregroundStyle(.white)
							.frame(width: 36, height: 36)
							.background(Circle().fill(.black.opacity(0.45)))
					}
					.padding(.trailing, 16)
				} else {
					Color.clear.frame(width: 36, height: 36).padding(.trailing, 16)
				}
			}
			.padding(.top, 8)
			Spacer()
		}
	}
}

// MARK: – Single page

private struct GalleryPage: View {
	let item: GalleryMediaItem
	let pageIndex: Int
	@Binding var currentIndex: Int
	@ObservedObject var vm: ChatDetailViewModel
	@Binding var isZoomed: Bool
	let panOffset: CGSize          // controlled by parent when zoomed

	@State private var scale: CGFloat = 1
	@State private var lastScale: CGFloat = 1
	@State private var player: AVPlayer? = nil

	var isCurrent: Bool { pageIndex == currentIndex }

	var body: some View {
		GeometryReader { geo in
			ZStack {
				if item.isVideo {
					videoContent
				} else {
					imageContent(geo: geo)
				}
			}
			.frame(width: geo.size.width, height: geo.size.height)
		}
		.onChange(of: currentIndex) { _, newIdx in
			if newIdx != pageIndex {
				resetZoom()
				player?.pause()
			} else if item.isVideo, let p = player {
				p.seek(to: .zero); p.play()
			}
		}
	}

	// MARK: Image (no DragGesture — pager handles all drags)

	@ViewBuilder
	private func imageContent(geo: GeometryProxy) -> some View {
		if let urlStr = vm.mediaURLCache[item.id], let url = URL(string: urlStr) {
			AsyncImage(url: url) { phase in
				switch phase {
				case .success(let img):
					img.resizable().scaledToFit()
						.frame(width: geo.size.width, height: geo.size.height)
						.scaleEffect(scale)
						.offset(panOffset)               // applied by parent
						.gesture(magnifyGesture)         // only zoom, no drag
						.onTapGesture(count: 2) { doubleTap() }
				case .failure:
					ProgressView().tint(.white)
						.task {
							vm.mediaURLCache.removeValue(forKey: item.id)
							_ = await vm.loadMediaURL(mediaId: item.id)
						}
				default:
					ProgressView().tint(.white)
				}
			}
		} else {
			ProgressView().tint(.white)
				.task { _ = await vm.loadMediaURL(mediaId: item.id) }
		}
	}

	// MARK: Video

	@ViewBuilder
	private var videoContent: some View {
		if let urlStr = vm.mediaURLCache[item.id], let url = URL(string: urlStr) {
			Group {
				if let p = player {
					VideoPlayer(player: p).ignoresSafeArea()
				} else {
					Color.black.onAppear {
						let p = AVPlayer(url: url)
						player = p
						if isCurrent { p.play() }
					}
				}
			}
		} else {
			ProgressView().tint(.white)
				.task { _ = await vm.loadMediaURL(mediaId: item.id) }
		}
	}

	// MARK: Zoom

	private var magnifyGesture: some Gesture {
		MagnificationGesture()
			.onChanged { v in
				scale = max(1, min(lastScale * v, 6))
				isZoomed = scale > 1.05
			}
			.onEnded { _ in
				lastScale = scale
				if scale < 1.1 { resetZoom() }
			}
	}

	private func doubleTap() {
		withAnimation(.spring(response: 0.3)) {
			if scale > 1.5 { resetZoom() }
			else { scale = 3; lastScale = 3; isZoomed = true }
		}
	}

	private func resetZoom() {
		withAnimation(.spring(response: 0.3)) {
			scale = 1; lastScale = 1
		}
		isZoomed = false
	}
}
