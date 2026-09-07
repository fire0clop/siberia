// Features/Stories/StoryViewerView.swift
//
// Полноэкранный просмотрщик сторис: прогресс-бары, автопереход по таймеру
// (фото — 5 секунд, видео — по окончании/тапу), тап справа/слева — вперёд/назад,
// свайп вниз — закрыть. Автор видит счётчик просмотров и может удалить.

import AVKit
import SwiftUI

struct StoryViewerView: View {
	let groups: [StoryFeedGroup]
	let startGroupIndex: Int
	let currentUserId: Int?
	let onClose: () -> Void
	/// Дёргается после действий, меняющих ленту (просмотр/удаление)
	let onFeedChanged: () -> Void

	@State private var groupIndex: Int
	@State private var storyIndex = 0
	@State private var progress: Double = 0
	@State private var timerTask: Task<Void, Never>? = nil
	@State private var showViewers = false
	@State private var viewers: [User] = []
	@State private var dragOffset: CGFloat = 0

	private static let photoDuration: Double = 5.0
	private static let tick: Double = 0.05

	init(
		groups: [StoryFeedGroup], startGroupIndex: Int, currentUserId: Int?,
		onClose: @escaping () -> Void, onFeedChanged: @escaping () -> Void
	) {
		self.groups = groups
		self.startGroupIndex = startGroupIndex
		self.currentUserId = currentUserId
		self.onClose = onClose
		self.onFeedChanged = onFeedChanged
		_groupIndex = State(initialValue: startGroupIndex)
	}

	private var group: StoryFeedGroup? {
		groups.indices.contains(groupIndex) ? groups[groupIndex] : nil
	}
	private var story: StoryItem? {
		guard let g = group, g.stories.indices.contains(storyIndex) else { return nil }
		return g.stories[storyIndex]
	}
	private var isOwn: Bool { group?.user.id == currentUserId }

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			if let story {
				mediaView(story)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}

			VStack(spacing: 10) {
				progressBars
				header
				Spacer()
				if let caption = story?.caption, !caption.isEmpty {
					Text(caption)
						.font(.subheadline)
						.foregroundStyle(.white)
						.padding(.horizontal, 14).padding(.vertical, 8)
						.background(Capsule().fill(.black.opacity(0.45)))
						.padding(.bottom, 24)
				}
				if isOwn, let s = story {
					ownFooter(s)
				}
			}
			.padding(.top, 8)

			// Тап-зоны: слева назад, справа вперёд
			HStack(spacing: 0) {
				Color.clear.contentShape(Rectangle())
					.onTapGesture { goPrev() }
				Color.clear.contentShape(Rectangle())
					.onTapGesture { goNext() }
			}
		}
		.offset(y: dragOffset)
		.gesture(
			DragGesture(minimumDistance: 20)
				.onChanged { v in if v.translation.height > 0 { dragOffset = v.translation.height } }
				.onEnded { v in
					if v.translation.height > 110 { onClose() } else { dragOffset = 0 }
				}
		)
		.statusBarHidden(true)
		.task(id: "\(groupIndex)-\(storyIndex)") { await presentCurrent() }
		.onDisappear { timerTask?.cancel() }
		.sheet(isPresented: $showViewers) { viewersSheet }
	}

	// MARK: – Media

	@ViewBuilder
	private func mediaView(_ s: StoryItem) -> some View {
		if let urlStr = s.mediaUrl, let url = URL(string: urlStr) {
			if s.mediaType == "video" {
				StoryVideoPlayer(url: url) { goNext() }
			} else {
				AsyncImage(url: url) { ph in
					switch ph {
					case .success(let img): img.resizable().scaledToFit()
					case .failure:
						VStack(spacing: 8) {
							Image(systemName: "photo.badge.exclamationmark").font(.largeTitle)
							Text("Не удалось загрузить").font(.caption)
						}
						.foregroundStyle(.white.opacity(0.6))
					default: ProgressView().tint(.white)
					}
				}
			}
		} else {
			ProgressView().tint(.white)
		}
	}

	// MARK: – Chrome

	private var progressBars: some View {
		HStack(spacing: 4) {
			if let g = group {
				ForEach(Array(g.stories.enumerated()), id: \.offset) { i, _ in
					GeometryReader { geo in
						ZStack(alignment: .leading) {
							Capsule().fill(.white.opacity(0.3))
							Capsule().fill(.white)
								.frame(width: geo.size.width * barFill(i))
						}
					}
					.frame(height: 3)
				}
			}
		}
		.padding(.horizontal, 12)
	}

	private func barFill(_ i: Int) -> Double {
		if i < storyIndex { return 1 }
		if i == storyIndex { return progress }
		return 0
	}

	private var header: some View {
		HStack(spacing: 10) {
			Circle().fill(.white.opacity(0.25))
				.frame(width: 34, height: 34)
				.overlay(
					Text(String((group?.user.nickname ?? "?").prefix(1)).uppercased())
						.font(.subheadline.bold()).foregroundStyle(.white)
				)
			Text(isOwn ? "Моя история" : (group?.user.nickname ?? ""))
				.font(.subheadline.weight(.semibold)).foregroundStyle(.white)
			Spacer()
			Button { onClose() } label: {
				Image(systemName: "xmark")
					.font(.system(size: 16, weight: .semibold))
					.foregroundStyle(.white)
					.frame(width: 36, height: 36)
			}
			.accessibilityLabel("Закрыть")
		}
		.padding(.horizontal, 12)
	}

	private func ownFooter(_ s: StoryItem) -> some View {
		HStack(spacing: 18) {
			Button {
				timerTask?.cancel()
				Task {
					viewers = (try? await StoriesService.shared.viewers(storyId: s.id)) ?? []
					showViewers = true
				}
			} label: {
				Label("\(s.viewsCount ?? 0)", systemImage: "eye")
					.font(.subheadline).foregroundStyle(.white)
			}
			Button(role: .destructive) {
				Task {
					try? await StoriesService.shared.delete(storyId: s.id)
					onFeedChanged()
					onClose()
				}
			} label: {
				Image(systemName: "trash").font(.subheadline).foregroundStyle(.white)
			}
		}
		.padding(.bottom, 18)
	}

	private var viewersSheet: some View {
		NavigationStack {
			List(viewers, id: \.id) { u in
				HStack(spacing: 10) {
					Circle().fill(Color.accentColor.opacity(0.2))
						.frame(width: 34, height: 34)
						.overlay(Text(String(u.nickname.prefix(1)).uppercased()).font(.subheadline.bold()))
					Text(u.nickname)
				}
			}
			.navigationTitle("Просмотрели")
			.navigationBarTitleDisplayMode(.inline)
		}
		.presentationDetents([.medium])
		.onDisappear { restartTimer() }
	}

	// MARK: – Навигация и таймер

	private func presentCurrent() async {
		guard let s = story else { onClose(); return }
		progress = 0
		// Отмечаем просмотр (best-effort) и обновляем ленту у родителя
		if !s.viewed && !isOwn {
			Task {
				try? await StoriesService.shared.markViewed(storyId: s.id)
				onFeedChanged()
			}
		}
		if s.mediaType != "video" { restartTimer() } else { timerTask?.cancel() }
	}

	private func restartTimer() {
		timerTask?.cancel()
		timerTask = Task { @MainActor in
			while !Task.isCancelled && progress < 1 {
				try? await Task.sleep(nanoseconds: UInt64(Self.tick * 1_000_000_000))
				guard !Task.isCancelled else { return }
				progress = min(1, progress + Self.tick / Self.photoDuration)
			}
			if !Task.isCancelled { goNext() }
		}
	}

	private func goNext() {
		timerTask?.cancel()
		guard let g = group else { onClose(); return }
		if storyIndex + 1 < g.stories.count {
			storyIndex += 1
		} else if groupIndex + 1 < groups.count {
			groupIndex += 1
			storyIndex = 0
		} else {
			onClose()
		}
	}

	private func goPrev() {
		timerTask?.cancel()
		if storyIndex > 0 {
			storyIndex -= 1
		} else if groupIndex > 0 {
			groupIndex -= 1
			storyIndex = max(0, (groups[groupIndex].stories.count) - 1)
		} else {
			progress = 0
			restartTimer()
		}
	}
}

// MARK: – Видео-плеер с колбэком окончания

private struct StoryVideoPlayer: View {
	let url: URL
	let onFinished: () -> Void

	@State private var player = AVPlayer()

	var body: some View {
		VideoPlayer(player: player)
			.onAppear {
				player.replaceCurrentItem(with: AVPlayerItem(url: url))
				player.play()
				NotificationCenter.default.addObserver(
					forName: .AVPlayerItemDidPlayToEndTime,
					object: player.currentItem, queue: .main
				) { _ in onFinished() }
			}
			.onDisappear { player.pause() }
	}
}
