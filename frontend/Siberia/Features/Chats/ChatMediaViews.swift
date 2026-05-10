import SwiftUI

// MARK: – Album thumbnail (stable identity so .task fires once)

struct AlbumThumbView: View {
	let m: ChatMessage
	let size: CGFloat
	@ObservedObject var vm: ChatDetailViewModel
	let onTap: () -> Void

	private var mediaId: String { m.mediaId ?? "" }
	private var isVideo: Bool { m.mediaType == "video" || m.mediaType == "video_note" }

	var body: some View {
		ZStack {
			if isVideo {
				videoContent
			} else {
				imageContent
			}
		}
		.frame(width: size, height: size).clipped()
		.contentShape(Rectangle())
		.onTapGesture { onTap() }
	}

	@ViewBuilder
	private var imageContent: some View {
		if let s = vm.mediaURLCache[mediaId], let url = URL(string: s) {
			AsyncImage(url: url) { ph in
				switch ph {
				case .success(let img):
					img.resizable().scaledToFill()
				case .failure:
					thumbPlaceholder.task {
						vm.mediaURLCache.removeValue(forKey: mediaId)
						_ = await vm.loadMediaURL(mediaId: mediaId)
					}
				default:
					thumbPlaceholder
				}
			}
		} else {
			thumbPlaceholder.task { _ = await vm.loadMediaURL(mediaId: mediaId) }
		}
	}

	@ViewBuilder
	private var videoContent: some View {
		ZStack {
			if let thumbStr = vm.mediaThumbURLCache[mediaId], let url = URL(string: thumbStr) {
				AsyncImage(url: url) { ph in
					if case .success(let img) = ph { img.resizable().scaledToFill() }
					else { thumbPlaceholder }
				}
			} else if let ui = vm.videoThumbnailCache[mediaId] {
				Image(uiImage: ui).resizable().scaledToFill()
			} else {
				thumbPlaceholder.task { await vm.loadVideoPreview(mediaId: mediaId) }
			}
			ZStack {
				Circle().fill(.black.opacity(0.45)).frame(width: 36, height: 36)
				Image(systemName: "play.fill")
					.font(.system(size: 14, weight: .bold))
					.foregroundStyle(.white).offset(x: 1)
			}
		}
	}

	private var thumbPlaceholder: some View {
		Color(.secondarySystemBackground)
			.overlay(ProgressView().tint(.secondary).scaleEffect(0.7))
	}
}

// MARK: – Reply quote thumbnail

struct ReplyThumbnailView: View {
	let mediaId: String
	let mediaType: String
	let mine: Bool
	@ObservedObject var vm: ChatDetailViewModel

	private let sz: CGFloat = 28

	var body: some View {
		ZStack {
			if mediaType == "image" {
				if let s = vm.mediaURLCache[mediaId], let url = URL(string: s) {
					AsyncImage(url: url) { ph in
						switch ph {
						case .success(let img):
							img.resizable().scaledToFill()
						case .failure:
							thumb(systemName: "photo.fill").task {
								vm.mediaURLCache.removeValue(forKey: mediaId)
								_ = await vm.loadMediaURL(mediaId: mediaId)
							}
						default:
							thumb(systemName: "photo.fill")
						}
					}
				} else {
					thumb(systemName: "photo.fill")
						.task { _ = await vm.loadMediaURL(mediaId: mediaId) }
				}
			} else if mediaType == "video" || mediaType == "video_note" {
				if let ui = vm.videoThumbnailCache[mediaId] {
					ZStack {
						Image(uiImage: ui).resizable().scaledToFill()
						Image(systemName: "play.fill")
							.font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
					}
				} else {
					thumb(systemName: "video.fill")
						.task { await vm.loadVideoPreview(mediaId: mediaId) }
				}
			} else {
				thumb(systemName: mediaType == "voice" ? "mic.fill" : mediaType == "audio" ? "music.note" : "doc.fill")
			}
		}
		.frame(width: sz, height: sz)
		.clipShape(RoundedRectangle(cornerRadius: 6))
	}

	private func thumb(systemName: String) -> some View {
		ZStack {
			Color(mine ? UIColor.white.withAlphaComponent(0.2) : UIColor.systemGray5)
			Image(systemName: systemName)
				.font(.system(size: 11))
				.foregroundStyle(mine ? Color.white.opacity(0.6) : ChatDetailView.accent.opacity(0.7))
		}
	}
}

// MARK: – Video thumbnail (with AVAssetImageGenerator fallback)

struct VideoThumbView: View {
	let mediaId: String
	@ObservedObject var vm: ChatDetailViewModel
	let onTap: () -> Void

	var body: some View {
		ZStack {
			if let s = vm.mediaThumbURLCache[mediaId], let url = URL(string: s) {
				AsyncImage(url: url) { ph in
					if case .success(let img) = ph { img.resizable().scaledToFill() }
					else { backdrop }
				}
			} else if let uiImg = vm.videoThumbnailCache[mediaId] {
				Image(uiImage: uiImg).resizable().scaledToFill()
			} else {
				backdrop.task { await vm.loadVideoPreview(mediaId: mediaId) }
			}
			Circle().fill(.black.opacity(0.4)).frame(width: 52, height: 52)
			Image(systemName: "play.fill")
				.font(.system(size: 21, weight: .bold))
				.foregroundStyle(.white).offset(x: 2)
		}
		.frame(maxWidth: .infinity, minHeight: 180)
		.contentShape(Rectangle())
		.onTapGesture { onTap() }
	}

	private var backdrop: some View {
		LinearGradient(
			colors: [Color(red: 0.12, green: 0.12, blue: 0.22),
			         Color(red: 0.06, green: 0.06, blue: 0.14)],
			startPoint: .topLeading, endPoint: .bottomTrailing
		)
	}
}

// MARK: – Profile media thumbnail (images + videos in gallery grid)

struct ProfileThumb: View {
	let item: GalleryMediaItem
	@ObservedObject var vm: ChatDetailViewModel

	var body: some View {
		ZStack {
			if item.isVideo { videoContent } else { imageContent }
		}
		.frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
	}

	@ViewBuilder
	private var imageContent: some View {
		if let urlStr = vm.mediaURLCache[item.id], let url = URL(string: urlStr) {
			AsyncImage(url: url) { phase in
				if case .success(let img) = phase { img.resizable().scaledToFill() }
				else { Color(.systemFill) }
			}
		} else {
			Color(.systemFill)
				.task { _ = await vm.loadMediaURL(mediaId: item.id) }
		}
	}

	@ViewBuilder
	private var videoContent: some View {
		if let thumbStr = vm.mediaThumbURLCache[item.id], let url = URL(string: thumbStr) {
			ZStack {
				AsyncImage(url: url) { phase in
					if case .success(let img) = phase { img.resizable().scaledToFill() }
					else { Color(.systemFill) }
				}
				playIcon
			}
		} else if let uiImg = vm.videoThumbnailCache[item.id] {
			ZStack {
				Image(uiImage: uiImg).resizable().scaledToFill()
				playIcon
			}
		} else {
			Color(.systemFill)
				.overlay(playIcon)
				.task { await vm.loadVideoPreview(mediaId: item.id) }
		}
	}

	private var playIcon: some View {
		ZStack {
			Circle().fill(.black.opacity(0.45)).frame(width: 28, height: 28)
			Image(systemName: "play.fill")
				.font(.system(size: 11, weight: .bold))
				.foregroundStyle(.white)
				.offset(x: 1)
		}
	}
}
