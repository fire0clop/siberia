import SwiftUI

// MARK: – Identifiable wrapper for a media ID in profile sheet

struct ProfileMediaId: Identifiable {
	let id: String
	init(_ id: String) { self.id = id }
}

// MARK: – Profile document item

struct ProfileDocItem: Identifiable {
	let id: String
	let mediaType: String
	let name: String
	let msgId: Int
}

// MARK: – Safe subscript for profile fullscreen

private extension Collection {
	subscript(safe index: Index) -> Element? {
		indices.contains(index) ? self[index] : nil
	}
}

// MARK: – Partner profile sheet (DM)

struct PartnerProfileSheet: View {
	let member: ChatMember?
	let title: String
	let colorSeed: Int
	@ObservedObject var vm: ChatDetailViewModel
	@Environment(\.dismiss) private var dismiss

	@State private var selectedTab = 0
	@State private var fullscreenMediaId: ProfileMediaId? = nil
	@State private var fullscreenItems: [GalleryMediaItem] = []
	@State private var isMuted = false
	@State private var showMuteSheet = false
	@State private var actionError: String?

	private let palette: [Color] = [.blue, .purple, .orange, .pink, .green, .teal, .indigo, .cyan]
	private var accent: Color { palette[abs(colorSeed) % palette.count] }
	private var nickname: String { member?.user.nickname ?? title }
	private var email: String? { member?.user.email }
	private var bio: String? { member?.user.bio }

	private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

	private var photoItems: [GalleryMediaItem] {
		Array(vm.allMediaItems.filter { !$0.isVideo }.reversed())
	}
	private var videoItems: [GalleryMediaItem] {
		Array(vm.allMediaItems.filter { $0.isVideo }.reversed())
	}
	private var docItems: [ProfileDocItem] {
		vm.messages
			.filter { m in
				guard let t = m.mediaType, !m.isDeleted else { return false }
				return t == "document" || t == "audio" || t == "voice"
			}
			.reversed()
			.compactMap { m -> ProfileDocItem? in
				guard let mid = m.mediaId, mid != "pending", let t = m.mediaType else { return nil }
				let name = vm.mediaOriginalNames[mid] ?? m.text ?? "Файл"
				return ProfileDocItem(id: mid, mediaType: t, name: name, msgId: m.id)
			}
	}
	private var hasAnyMedia: Bool { !vm.allMediaItems.isEmpty || !docItems.isEmpty }

	var body: some View {
		NavigationStack {
			ScrollView(showsIndicators: false) {
				VStack(spacing: 0) {

					// ── Gradient header ──────────────────────────────
					ZStack(alignment: .bottom) {
						LinearGradient(
							colors: [accent.opacity(0.85), accent.opacity(0.25)],
							startPoint: .topLeading, endPoint: .bottomTrailing
						)
						.frame(height: 150)

						ZStack {
							Circle()
								.fill(accent)
								.frame(width: 90, height: 90)
								.shadow(color: accent.opacity(0.45), radius: 14, y: 5)
							Text(String(nickname.prefix(1)).uppercased())
								.font(.system(size: 40, weight: .bold))
								.foregroundStyle(.white)
						}
						.offset(y: 45)
					}
					.ignoresSafeArea(edges: .top)

					// ── Name + email + bio ──────────────────────────
					VStack(spacing: 6) {
						Text(nickname)
							.font(.title2.bold())
							.padding(.top, 52)
						if let email {
							Text(email)
								.font(.subheadline)
								.foregroundStyle(.secondary)
						}
						if let bio, !bio.isEmpty {
							Text(bio)
								.font(.footnote)
								.foregroundStyle(.secondary)
								.multilineTextAlignment(.center)
								.padding(.horizontal, 24)
								.padding(.top, 4)
						}
					}
					.padding(.bottom, 16)

					// ── Quick actions: mute / block ─────────────────
					quickActionsRow
						.padding(.horizontal, 16)
						.padding(.bottom, 20)

					// ── Media tabs ───────────────────────────────────
					if hasAnyMedia {
						VStack(spacing: 0) {
							Picker("", selection: $selectedTab) {
								Text("Фото").tag(0)
								Text("Видео").tag(1)
								Text("Документы").tag(2)
							}
							.pickerStyle(.segmented)
							.padding(.horizontal, 16)
							.padding(.top, 4)
							.padding(.bottom, 12)

							tabContent
						}
					}

					Spacer(minLength: 48)
				}
			}
			.ignoresSafeArea(edges: .top)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Готово") { dismiss() }
						.fontWeight(.semibold)
				}
			}
		}
		.fullScreenCover(item: $fullscreenMediaId) { wrapper in
			ProfileMediaFullscreen(
				startMediaId: wrapper.id,
				items: fullscreenItems,
				vm: vm,
				onGoToMessage: { msgId in vm.jumpToMessageId = msgId }
			)
		}
		.confirmationDialog("Уведомления", isPresented: $showMuteSheet, titleVisibility: .visible) {
			Button("Отключить на 1 час")    { Task { await muteFor(hours: 1) } }
			Button("Отключить на 8 часов")  { Task { await muteFor(hours: 8) } }
			Button("Отключить навсегда")    { Task { await muteFor(hours: nil) } }
			Button("Отмена", role: .cancel) {}
		}
		.alert("Ошибка", isPresented: .init(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
			Button("OK", role: .cancel) { actionError = nil }
		} message: { Text(actionError ?? "") }
	}

	// MARK: – Quick actions row (mute / block)

	private var quickActionsRow: some View {
		HStack(spacing: 10) {
			actionButton(
				icon: isMuted ? "bell.slash.fill" : "bell.fill",
				label: isMuted ? "Включить" : "Отключить",
				color: .orange
			) {
				Task {
					if isMuted { await unmute() }
					else { showMuteSheet = true }
				}
			}
			actionButton(icon: "hand.raised.fill", label: "Заблокировать", color: .red) {
				Task { await blockPartner() }
			}
		}
	}

	private func actionButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(spacing: 4) {
				Image(systemName: icon)
					.font(.system(size: 18, weight: .semibold))
					.foregroundStyle(color)
				Text(label)
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(.primary)
			}
			.frame(maxWidth: .infinity)
			.padding(.vertical, 10)
			.background(Color(.secondarySystemBackground))
			.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
		}
		.buttonStyle(.plain)
	}

	@MainActor private func muteFor(hours: Int?) async {
		do {
			let until: Date? = hours.map { Date().addingTimeInterval(TimeInterval($0 * 3600)) }
			try await ChatService.shared.mute(chatId: vm.chatId, until: until)
			isMuted = true
		} catch {
			Log.chat.error("mute failed: \(String(describing: error))")
			actionError = error.localizedDescription
		}
	}

	@MainActor private func unmute() async {
		do {
			try await ChatService.shared.unmute(chatId: vm.chatId)
			isMuted = false
		} catch {
			Log.chat.error("unmute failed: \(String(describing: error))")
			actionError = error.localizedDescription
		}
	}

	@MainActor private func blockPartner() async {
		guard let uid = member?.userId else { return }
		do {
			try await UserService.shared.block(userId: uid)
			dismiss()
			NotificationCenter.default.post(name: .siberiaChatsShouldReload, object: nil)
		} catch {
			Log.profile.error("block failed: \(String(describing: error))")
			actionError = error.localizedDescription
		}
	}

	// MARK: – Tab content

	@ViewBuilder
	private var tabContent: some View {
		switch selectedTab {
		case 0:
			if photoItems.isEmpty {
				emptyTabLabel("Нет фотографий")
			} else {
				LazyVGrid(columns: columns, spacing: 2) {
					ForEach(photoItems) { item in
						ProfileThumb(item: item, vm: vm)
							.aspectRatio(1, contentMode: .fill)
							.clipped()
							.contentShape(Rectangle())
							.onTapGesture {
								fullscreenItems = photoItems
								fullscreenMediaId = ProfileMediaId(item.id)
							}
					}
				}
				.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
				.padding(.horizontal, 2)
			}
		case 1:
			if videoItems.isEmpty {
				emptyTabLabel("Нет видео")
			} else {
				LazyVGrid(columns: columns, spacing: 2) {
					ForEach(videoItems) { item in
						ProfileThumb(item: item, vm: vm)
							.aspectRatio(1, contentMode: .fill)
							.clipped()
							.contentShape(Rectangle())
							.onTapGesture {
								fullscreenItems = videoItems
								fullscreenMediaId = ProfileMediaId(item.id)
							}
					}
				}
				.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
				.padding(.horizontal, 2)
			}
		default:
			if docItems.isEmpty {
				emptyTabLabel("Нет документов")
			} else {
				LazyVStack(spacing: 0) {
					ForEach(docItems) { doc in
						docRow(doc)
						Divider().padding(.leading, 56)
					}
				}
				.background(Color(.secondarySystemBackground))
				.clipShape(RoundedRectangle(cornerRadius: 12))
				.padding(.horizontal, 12)
			}
		}
	}

	private func docRow(_ doc: ProfileDocItem) -> some View {
		HStack(spacing: 12) {
			ZStack {
				RoundedRectangle(cornerRadius: 10)
					.fill(accent.opacity(0.12))
					.frame(width: 40, height: 40)
				Image(systemName: docIcon(doc.mediaType))
					.font(.system(size: 18))
					.foregroundStyle(accent)
			}
			VStack(alignment: .leading, spacing: 2) {
				Text(doc.name)
					.font(.subheadline.weight(.medium))
					.lineLimit(1)
				Text(docTypeName(doc.mediaType))
					.font(.caption)
					.foregroundStyle(.secondary)
			}
			Spacer()
			Button {
				dismiss()
				vm.jumpToMessageId = doc.msgId
			} label: {
				Image(systemName: "arrow.up.message.fill")
					.font(.system(size: 14))
					.foregroundStyle(accent)
					.padding(8)
					.background(Circle().fill(accent.opacity(0.1)))
			}
		}
		.padding(.horizontal, 14)
		.padding(.vertical, 10)
	}

	private func docIcon(_ type: String) -> String {
		switch type {
		case "voice":  return "mic.fill"
		case "audio":  return "music.note"
		default:       return "doc.fill"
		}
	}

	private func docTypeName(_ type: String) -> String {
		switch type {
		case "voice":  return "Голосовое"
		case "audio":  return "Аудио"
		default:       return "Документ"
		}
	}

	private func emptyTabLabel(_ text: String) -> some View {
		Text(text)
			.font(.subheadline)
			.foregroundStyle(.secondary)
			.frame(maxWidth: .infinity)
			.padding(.vertical, 40)
	}
}

// MARK: – Fullscreen viewer from profile sheet

struct ProfileMediaFullscreen: View {
	let startMediaId: String
	let items: [GalleryMediaItem]
	@ObservedObject var vm: ChatDetailViewModel
	let onGoToMessage: (Int) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var currentIndex: Int
	@State private var showControls = true

	init(startMediaId: String, items: [GalleryMediaItem],
	     vm: ChatDetailViewModel, onGoToMessage: @escaping (Int) -> Void) {
		self.startMediaId = startMediaId
		self.items = items
		self.vm = vm
		self.onGoToMessage = onGoToMessage
		let idx = items.firstIndex(where: { $0.id == startMediaId }) ?? 0
		self._currentIndex = State(initialValue: idx)
	}

	private var currentItem: GalleryMediaItem? { items[safe: currentIndex] }

	var body: some View {
		ZStack {
			Color.black.ignoresSafeArea()

			MediaGalleryView(items: items, startIndex: currentIndex, vm: vm)
				.onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() } }

			if showControls {
				VStack {
					HStack {
						Button { dismiss() } label: {
							Image(systemName: "xmark")
								.font(.system(size: 16, weight: .semibold))
								.foregroundStyle(.white)
								.frame(width: 38, height: 38)
								.background(Circle().fill(.black.opacity(0.5)))
						}
						.padding(.leading, 16)
						Spacer()
					}
					.padding(.top, 8)
					Spacer()

					HStack {
						Spacer()
						if let item = currentItem,
						   let msgId = vm.mediaToMessageId[item.id] {
							Button {
								dismiss()
								onGoToMessage(msgId)
							} label: {
								HStack(spacing: 6) {
									Image(systemName: "arrow.up.message.fill")
										.font(.system(size: 14, weight: .semibold))
									Text("В чат")
										.font(.system(size: 15, weight: .semibold))
								}
								.foregroundStyle(.white)
								.padding(.horizontal, 16)
								.padding(.vertical, 10)
								.background(Capsule().fill(.black.opacity(0.55)))
							}
							.padding(.trailing, 20)
							.padding(.bottom, 36)
						}
					}
				}
				.transition(.opacity)
			}
		}
		.statusBarHidden()
	}
}
