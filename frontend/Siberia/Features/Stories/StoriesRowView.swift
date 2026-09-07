// Features/Stories/StoriesRowView.swift
//
// Горизонтальный ряд кружков-сторис над списком чатов.
// Свой кружок с «+» — всегда первый (создание через PhotosPicker),
// у друзей градиентное кольцо пока есть непросмотренное, серое — после.

import PhotosUI
import SwiftUI

struct StoriesRowView: View {
	let groups: [StoryFeedGroup]
	let currentUserId: Int?
	let onOpenGroup: (Int) -> Void   // индекс группы в groups
	let onFeedChanged: () -> Void

	@State private var pickerItems: [PhotosPickerItem] = []
	@State private var isUploading = false
	@State private var uploadError: String?

	private var ownGroupIndex: Int? {
		groups.firstIndex(where: { $0.user.id == currentUserId })
	}

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 14) {
				myCircle
				ForEach(Array(groups.enumerated()), id: \.element.id) { idx, g in
					if g.user.id != currentUserId {
						storyCircle(g) { onOpenGroup(idx) }
					}
				}
			}
			.padding(.horizontal, 16).padding(.vertical, 8)
		}
		.alert("Не удалось опубликовать", isPresented: .init(
			get: { uploadError != nil }, set: { if !$0 { uploadError = nil } }
		)) {
			Button("OK", role: .cancel) { uploadError = nil }
		} message: { Text(uploadError ?? "") }
		.onChange(of: pickerItems) { _, items in
			guard let item = items.first else { return }
			pickerItems = []
			Task { await publishStory(item) }
		}
	}

	// MARK: – Свой кружок

	private var myCircle: some View {
		VStack(spacing: 4) {
			ZStack(alignment: .bottomTrailing) {
				// Если у меня есть активные сторис — тап открывает их
				if let idx = ownGroupIndex {
					Button { onOpenGroup(idx) } label: { avatarCircle("Я", ringed: true, viewed: groups[idx].allViewed) }
						.buttonStyle(.plain)
				} else {
					avatarCircle("Я", ringed: false, viewed: false)
				}
				PhotosPicker(selection: $pickerItems, maxSelectionCount: 1,
				             matching: .any(of: [.images, .videos])) {
					ZStack {
						Circle().fill(Color.accentColor).frame(width: 20, height: 20)
						if isUploading {
							ProgressView().tint(.white).scaleEffect(0.5)
						} else {
							Image(systemName: "plus")
								.font(.system(size: 11, weight: .bold))
								.foregroundStyle(.white)
						}
					}
					.overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
				}
				.disabled(isUploading)
				.accessibilityLabel("Опубликовать историю")
			}
			Text("Моя").font(.caption2).foregroundStyle(.secondary)
		}
	}

	// MARK: – Кружок друга

	private func storyCircle(_ g: StoryFeedGroup, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(spacing: 4) {
				avatarCircle(g.user.nickname, ringed: true, viewed: g.allViewed)
				Text(g.user.nickname)
					.font(.caption2).foregroundStyle(.secondary)
					.lineLimit(1).frame(width: 62)
			}
		}
		.buttonStyle(.plain)
	}

	private func avatarCircle(_ name: String, ringed: Bool, viewed: Bool) -> some View {
		ZStack {
			if ringed {
				Circle()
					.stroke(
						viewed
							? AnyShapeStyle(Color(.systemGray3))
							: AnyShapeStyle(LinearGradient(
								colors: [Color(red: 0.38, green: 0.28, blue: 0.94),
								         Color(red: 0.85, green: 0.32, blue: 0.60)],
								startPoint: .topLeading, endPoint: .bottomTrailing)),
						lineWidth: 2.5
					)
					.frame(width: 58, height: 58)
			}
			Circle().fill(Color.accentColor.opacity(0.18))
				.frame(width: 50, height: 50)
				.overlay(
					Text(String(name.prefix(1)).uppercased())
						.font(.headline).foregroundStyle(Color.accentColor)
				)
		}
	}

	// MARK: – Публикация

	private func publishStory(_ item: PhotosPickerItem) async {
		isUploading = true
		defer { isUploading = false }
		do {
			guard let data = try await item.loadTransferable(type: Data.self) else {
				uploadError = "Не удалось прочитать файл"
				return
			}
			let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
			let media = try await MediaService.shared.upload(
				data: data,
				fileName: isVideo ? "story.mov" : "story.jpg",
				mimeType: isVideo ? "video/quicktime" : "image/jpeg",
				type: isVideo ? "video" : "image"
			)
			_ = try await StoriesService.shared.create(mediaId: media.id, caption: nil)
			onFeedChanged()
		} catch {
			uploadError = error.localizedDescription
		}
	}
}
