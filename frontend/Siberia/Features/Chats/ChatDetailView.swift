import AVKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: – Album grouping model

struct MessageGroup: Identifiable {
	let id: Int
	let messages: [ChatMessage]
	var isAlbum: Bool { messages.count > 1 }
	var first:   ChatMessage { messages[0] }
}

// MARK: – Chat list items (messages + date separators)

enum ChatItem: Identifiable {
	case separator(Date)
	case group(MessageGroup)
	var id: String {
		switch self {
		case .separator(let d): return "sep_\(Int(d.timeIntervalSince1970))"
		case .group(let g):     return "grp_\(g.id)"
		}
	}
}

// MARK: – Identifiable wrapper for sheet(item:) bindings

private struct MessageIdWrapper: Identifiable {
	let id: Int
}

// MARK: – Main View

struct ChatDetailView: View {

	@StateObject private var vm: ChatDetailViewModel
	@StateObject private var voice = VoiceRecorder()
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject private var appState: AppState

	// Partner profile
	@State private var showPartnerProfile = false

	// Sheets
	@State private var editingMessage: ChatMessage?
	@State private var editText = ""
	@State private var messageForReaction: ChatMessage?
	@State private var showForwardPicker = false

	// Media fullscreen
	@State private var galleryStartIndex: Int?
	@State private var fullscreenVideoURL: URL?

	// Swipe-to-reply + highlight
	@State private var swipeOffsets: [Int: CGFloat] = [:]
	@State private var highlightedMessageId: Int?

	// Attach menu
	@State private var showAttachMenu = false
	@State private var selectedPhotos: [PhotosPickerItem] = []
	@State private var showPhotoVideoPicker = false
	@State private var showFilePicker = false

	// Scheduled messages
	@State private var showScheduleSheet = false
	@State private var showScheduledList = false

	// Edit history modal
	@State private var historyMessageId: Int? = nil

	// Notification settings
	@State private var showNotifSettings = false

	// Delete confirmation
	@State private var deleteTarget: ChatMessage? = nil
	@State private var deleteCanForEveryone = false

	// MARK: – Color palette (internal so extracted views can reference ChatDetailView.accent)

	static let accent    = Color(red: 0.38, green: 0.28, blue: 0.94)
	static let mineGrad  = LinearGradient(
		colors: [Color(red: 0.32, green: 0.44, blue: 0.98), Color(red: 0.50, green: 0.22, blue: 0.90)],
		startPoint: .topLeading, endPoint: .bottomTrailing
	)
	static let otherBg   = Color(.systemBackground)
	static let chatBg    = Color(red: 0.95, green: 0.95, blue: 0.97)

	// Formatters
	private static let timeFmt: DateFormatter = {
		let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
	}()
	private static let isoFull: ISO8601DateFormatter = {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return f
	}()

	init(route: ChatRoute) {
		_vm = StateObject(wrappedValue: ChatDetailViewModel(
			chatId: route.chatId, title: route.title, initialSyncSeq: route.syncSeq
		))
	}

	// MARK: – body

	var body: some View {
		ZStack(alignment: .top) {
			Self.chatBg.ignoresSafeArea()

			VStack(spacing: 0) {
				chatHeader
				pinnedBanner
				messageList
				mentionBar
				replyBar
				ComposeBarView(
					vm: vm, voice: voice,
					showAttachMenu: $showAttachMenu,
					showPhotoVideoPicker: $showPhotoVideoPicker,
					showFilePicker: $showFilePicker,
					showScheduleSheet: $showScheduleSheet
				)
			}
			.overlay(alignment: .bottomLeading) {
				if showAttachMenu {
					AttachMenuCard(
						showAttachMenu: $showAttachMenu,
						showPhotoVideoPicker: $showPhotoVideoPicker,
						showFilePicker: $showFilePicker
					)
					.padding(.leading, 12)
					.padding(.bottom, 68)
					.transition(.scale(scale: 0.72, anchor: .bottomLeading).combined(with: .opacity))
					.zIndex(10)
				}
			}
			.animation(.spring(response: 0.22, dampingFraction: 0.75), value: showAttachMenu)

			errorToast
		}
		.navigationBarBackButtonHidden(true)
		.toolbar(.hidden, for: .navigationBar)
		.toolbar(.hidden, for: .tabBar)
		.task { await vm.onAppear() }
		.onDisappear { Task { await vm.onDisappear() } }
		.confirmationDialog(
			"Удалить сообщение?",
			isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
			titleVisibility: .visible
		) {
			if deleteCanForEveryone {
				Button("Удалить у всех", role: .destructive) {
					if let m = deleteTarget { Task { await vm.deleteMessage(m) } }
					deleteTarget = nil
				}
			}
			Button("Удалить у меня", role: .destructive) {
				if let m = deleteTarget { vm.deleteMessageLocally(m) }
				deleteTarget = nil
			}
			Button("Отмена", role: .cancel) { deleteTarget = nil }
		}
		.sheet(isPresented: $showPartnerProfile) {
			if vm.isGroup {
				GroupInfoSheet(vm: vm)
			} else {
				PartnerProfileSheet(
					member: vm.otherMember,
					title: vm.title,
					colorSeed: vm.otherMember?.userId ?? vm.chatId,
					vm: vm
				)
			}
		}
		.sheet(item: $editingMessage) { editSheet($0) }
		.sheet(item: $messageForReaction) { msg in
			ReactionPickerView(message: msg, currentUserId: vm.currentUserId) { emoji in
				Task { await vm.toggleReaction(emoji, on: msg) }
			}
		}
		.sheet(isPresented: $showForwardPicker) {
			if let m = vm.messageToForward {
				ForwardChatPicker { chat in Task { await vm.forwardMessage(m, to: chat.id) } }
			}
		}
		.fullScreenCover(item: $fullscreenVideoURL) { url in
			FullscreenVideoView(url: url)
		}
		.fullScreenCover(isPresented: Binding(
			get: { galleryStartIndex != nil },
			set: { if !$0 { galleryStartIndex = nil } }
		)) {
			if let idx = galleryStartIndex {
				MediaGalleryView(items: vm.allMediaItems, startIndex: idx, vm: vm)
			}
		}
		.photosPicker(
			isPresented: $showPhotoVideoPicker,
			selection: $selectedPhotos,
			maxSelectionCount: 10,
			matching: .any(of: [.images, .videos])
		)
		.onChange(of: selectedPhotos) { _, items in
			guard !items.isEmpty else { return }
			let toSend = items; selectedPhotos = []
			Task { await vm.sendPickedItems(toSend) }
		}
		.fileImporter(isPresented: $showFilePicker,
		              allowedContentTypes: [.item],
		              allowsMultipleSelection: true) { result in
			guard let urls = try? result.get() else { return }
			Task {
				for url in urls {
					guard url.startAccessingSecurityScopedResource() else { continue }
					defer { url.stopAccessingSecurityScopedResource() }
					guard let data = try? Data(contentsOf: url) else { continue }
					let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
					          ?? "application/octet-stream"
					await vm.sendDocument(data: data, fileName: url.lastPathComponent, mimeType: mime)
				}
			}
		}
		.onChange(of: vm.messageToForward) { _, m in if m != nil { showForwardPicker = true } }
		.sheet(isPresented: $showScheduleSheet) {
			ScheduleMessageSheet { date in
				Task { await sendScheduled(at: date) }
			}
			.presentationDetents([.medium])
		}
		.sheet(isPresented: $showScheduledList) {
			ScheduledMessagesSheet(chatId: vm.chatId)
		}
		.sheet(item: Binding(
			get: { historyMessageId.map { MessageIdWrapper(id: $0) } },
			set: { historyMessageId = $0?.id }
		)) { wrapper in
			EditHistorySheet(messageId: wrapper.id)
		}
		.sheet(isPresented: $showNotifSettings) {
			ChatNotificationSettingsSheet(chatId: vm.chatId, chatTitle: vm.title)
		}
	}

	@MainActor
	private func sendScheduled(at date: Date) async {
		let text = vm.draft.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !text.isEmpty else { return }
		vm.draft = ""
		do {
			_ = try await ChatService.shared.scheduleMessage(chatId: vm.chatId, text: text, sendAt: date)
			vm.error = "Сообщение отложено на \(scheduledFormatter.string(from: date))"
		} catch {
			Log.chat.error("scheduleMessage failed: \(String(describing: error))")
			vm.draft = text
			vm.error = error.localizedDescription
		}
	}

	private var scheduledFormatter: DateFormatter {
		let f = DateFormatter()
		f.locale = Locale(identifier: "ru_RU")
		f.dateFormat = "d MMM, HH:mm"
		return f
	}

	// MARK: – Chat header

	private var chatHeader: some View {
		HStack(spacing: 12) {
			Button { dismiss() } label: {
				Image(systemName: "chevron.left")
					.font(.system(size: 17, weight: .semibold))
					.foregroundStyle(Self.accent)
					.frame(width: 36, height: 36)
			}

			Button { showPartnerProfile = true } label: {
				ZStack(alignment: .bottomTrailing) {
					Group {
						if let member = vm.otherMember,
						   let urlStr = member.user.avatarUrl,
						   let url = URL(string: urlStr) {
							AsyncImage(url: url) { ph in
								if case .success(let img) = ph {
									img.resizable().scaledToFill()
								} else { avatarFallback }
							}
						} else {
							avatarFallback
						}
					}
					.frame(width: 40, height: 40)
					.clipShape(Circle())
					.overlay(Circle().stroke(Self.accent.opacity(0.25), lineWidth: 1.5))

					if vm.isPartnerOnline == true {
						OnlinePulse()
							.frame(width: 12, height: 12)
							.offset(x: 2, y: 2)
					}
				}
			}
			.buttonStyle(.plain)

			Button { showPartnerProfile = true } label: {
				VStack(alignment: .leading, spacing: 2) {
					Text(vm.title)
						.font(.system(size: 16, weight: .semibold))
						.foregroundStyle(.primary)
						.lineLimit(1)

					if !vm.typingNicknames.isEmpty {
						HStack(spacing: 4) {
							TypingDots()
							Text("печатает…")
								.font(.system(size: 12))
								.foregroundStyle(Self.accent)
						}
					} else if let online = vm.isPartnerOnline {
						Text(online ? "онлайн" : "не в сети")
							.font(.system(size: 12))
							.foregroundStyle(online ? Color(red: 0.22, green: 0.78, blue: 0.45) : .secondary)
					}
				}
				.animation(.easeInOut(duration: 0.2), value: vm.typingNicknames.count)
			}
			.buttonStyle(.plain)

			Spacer()

			// Кнопки звонка — только в 1-on-1
			if !vm.isGroup, let partner = vm.otherMember?.user {
				Button {
					print("📞 [TAP] audio call button pressed for peer=\(partner.id)")
					Task { await appState.startOutgoingCall(peer: partner, type: .audio) }
				} label: {
					Image(systemName: "phone.fill")
						.font(.system(size: 15, weight: .medium))
						.foregroundStyle(Self.accent)
						.frame(width: 36, height: 36)
						.background(Circle().fill(Self.accent.opacity(0.09)))
				}
				Button {
					print("📞 [TAP] video call button pressed for peer=\(partner.id)")
					Task { await appState.startOutgoingCall(peer: partner, type: .video) }
				} label: {
					Image(systemName: "video.fill")
						.font(.system(size: 15, weight: .medium))
						.foregroundStyle(Self.accent)
						.frame(width: 36, height: 36)
						.background(Circle().fill(Self.accent.opacity(0.09)))
				}
			}

			Menu {
				Button { showPartnerProfile = true } label: {
					Label("Информация", systemImage: "info.circle")
				}
				Button { showScheduledList = true } label: {
					Label("Отложенные", systemImage: "clock.arrow.circlepath")
				}
				Button { showNotifSettings = true } label: {
					let dnd = ChatNotificationSettingsStore.shared.schedule(for: vm.chatId)
					Label(dnd.enabled ? "Уведомления (\(dnd.displayString))" : "Уведомления",
					      systemImage: dnd.enabled ? "moon.fill" : "bell")
				}
			} label: {
				Image(systemName: "ellipsis")
					.font(.system(size: 15, weight: .medium))
					.foregroundStyle(Self.accent)
					.frame(width: 36, height: 36)
					.background(Circle().fill(Self.accent.opacity(0.09)))
			}
		}
		.padding(.horizontal, 8)
		.padding(.bottom, 10)
		.padding(.top, 4)
		.background(
			ZStack {
				Color(.systemBackground)
				LinearGradient(
					colors: [Self.accent.opacity(0.06), .clear],
					startPoint: .leading, endPoint: .trailing
				)
			}
			.ignoresSafeArea(edges: .top)
		)
		.overlay(
			Rectangle()
				.fill(Self.accent.opacity(0.10))
				.frame(height: 0.5),
			alignment: .bottom
		)
	}

	private var avatarFallback: some View {
		ZStack {
			LinearGradient(
				colors: [Self.accent, Color(red: 0.50, green: 0.22, blue: 0.90)],
				startPoint: .topLeading, endPoint: .bottomTrailing
			)
			Text(String(vm.title.prefix(1)).uppercased())
				.font(.system(size: 17, weight: .bold))
				.foregroundStyle(.white)
		}
	}

	// MARK: – Pinned banner

	@ViewBuilder
	private var pinnedBanner: some View {
		if let pin = vm.pinnedMessage {
			Button {
				vm.jumpToMessageId = pin.id
			} label: {
				HStack(spacing: 8) {
					Rectangle().fill(.orange).frame(width: 3).clipShape(Capsule())
					VStack(alignment: .leading, spacing: 1) {
						Text("Закреплено").font(.caption2.bold()).foregroundStyle(.orange)
						Text(pinPreview(pin)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
					}
					Spacer()
					Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange.opacity(0.7))
					if isMyChatAdmin {
						Button {
							Task { await unpinMessage() }
						} label: {
							Image(systemName: "xmark.circle.fill")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal, 14).padding(.vertical, 7)
				.background(.ultraThinMaterial)
				.overlay(Divider(), alignment: .bottom)
				.contentShape(Rectangle())
			}
			.buttonStyle(.plain)
		}
	}

	private func pinPreview(_ m: ChatMessage) -> String {
		if let t = m.text, !t.isEmpty { return t }
		switch m.mediaType {
		case "image": return "Фото"
		case "video": return "Видео"
		case "voice": return "Голосовое"
		case "audio": return "Аудио"
		default:      return "Медиа"
		}
	}

	private var isMyChatAdmin: Bool {
		guard let me = vm.currentUserId else { return false }
		let role = vm.chatMembers.first(where: { $0.userId == me })?.role
		return role == "admin" || role == "owner"
	}

	@MainActor
	private func unpinMessage() async {
		do {
			try await ChatService.shared.unpin(chatId: vm.chatId)
			vm.pinnedMessage = nil
		} catch {
			Log.chat.error("unpin failed: \(String(describing: error))")
			vm.error = error.localizedDescription
		}
	}

	@MainActor
	private func pinMessage(_ m: ChatMessage) async {
		do {
			try await ChatService.shared.pin(chatId: vm.chatId, messageId: m.id)
			vm.pinnedMessage = m
		} catch {
			Log.chat.error("pin failed: \(String(describing: error))")
			vm.error = error.localizedDescription
		}
	}

	// MARK: – Message list

	private var messageList: some View {
		ScrollViewReader { proxy in
			ZStack(alignment: .bottomTrailing) {
				ScrollView {
					LazyVStack(spacing: 1) {
						// Load-more trigger at the very top
						if vm.hasMoreMessages {
							Color.clear.frame(height: 1)
								.onAppear { Task { await vm.loadMore() } }
						}
						if vm.isLoadingMore {
							ProgressView().padding(.vertical, 8)
						}

						if vm.isLoading && vm.messages.isEmpty {
							MessageSkeletonView()
						} else {
							ForEach(buildItems(vm.messages)) { item in
								switch item {
								case .separator(let date):
									dateSeparatorView(date)
								case .group(let group):
									if group.isAlbum {
										albumRow(group)
									} else {
										messageRow(group.first, proxy: proxy)
									}
								}
							}
						}

						// Bottom sentinel: visible → user is at bottom
						Color.clear.frame(height: 1).id("__bottom__")
							.onAppear  { vm.setAtBottom(true) }
							.onDisappear { vm.setAtBottom(false) }
					}
					.padding(.vertical, 8)
				}
				.transaction { $0.animation = nil }
				.onChange(of: vm.scrollToBottomSignal) { _, _ in
					proxy.scrollTo("__bottom__", anchor: .bottom)
				}
				.onChange(of: vm.messages.count) { old, new in
					// Auto-scroll when new messages arrive and user was already at bottom
					if new > old && vm.isAtBottom {
						proxy.scrollTo("__bottom__", anchor: .bottom)
					}
				}
				.onChange(of: vm.jumpToMessageId) { _, id in
					guard let id else { return }
					showPartnerProfile = false
					DispatchQueue.main.asyncAfter(deadline: .now() + UIConstants.scrollToMessageDelay) {
						scrollToMessage(id, proxy: proxy)
						vm.jumpToMessageId = nil
					}
				}
				.scrollDismissesKeyboard(.interactively)
				.onTapGesture {
					UIApplication.shared.sendAction(
						#selector(UIResponder.resignFirstResponder),
						to: nil, from: nil, for: nil
					)
				}
				.simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in
					if showAttachMenu { withAnimation { showAttachMenu = false } }
				})
				.task {
					// Give layout time to render before scrolling to bottom
					try? await Task.sleep(nanoseconds: 80_000_000)
					proxy.scrollTo("__bottom__", anchor: .bottom)
				}

				if vm.showScrollToBottom {
					scrollFAB(proxy: proxy)
						.padding(.trailing, 12).padding(.bottom, 8)
						.transition(.scale.combined(with: .opacity))
						.animation(.easeInOut(duration: 0.15), value: vm.showScrollToBottom)
				}
			}
		}
	}

	// MARK: – Message row

	@ViewBuilder
	private func messageRow(_ m: ChatMessage, proxy: ScrollViewProxy) -> some View {
		if m.isSystem {
			HStack {
				Spacer()
				Text(m.text ?? "")
					.font(.caption.weight(.medium))
					.foregroundStyle(.secondary)
					.multilineTextAlignment(.center)
					.padding(.horizontal, 14)
					.padding(.vertical, 6)
					.background(.regularMaterial, in: Capsule())
				Spacer()
			}
			.padding(.vertical, 6)
			.id("msg_\(m.id)")
		} else {
			normalMessageRow(m, proxy: proxy)
		}
	}

	@ViewBuilder
	private func normalMessageRow(_ m: ChatMessage, proxy: ScrollViewProxy) -> some View {
		let mine = vm.isMine(m)
		let swipeOff = swipeOffsets[m.id] ?? 0
		ZStack {
			if swipeOff >= 0 {
				replyIconView(offset: swipeOff).padding(.leading, 16)
					.frame(maxWidth: .infinity, alignment: .leading)
			} else {
				replyIconView(offset: swipeOff).padding(.trailing, 16)
					.frame(maxWidth: .infinity, alignment: .trailing)
			}
			HStack(alignment: .bottom, spacing: 6) {
				if mine { Spacer(minLength: 52) }
				MessageBubbleView(
					message: m, mine: mine,
					vm: vm, voice: voice,
					onScrollTo: { id in scrollToMessage(id, proxy: proxy) },
					onOpenGallery: { galleryStartIndex = $0 },
					onSetHistoryId: { historyMessageId = $0 }
				)
				if !mine { Spacer(minLength: 52) }
			}
			.padding(.horizontal, 10).padding(.vertical, 2)
			.contentShape(Rectangle())
			.offset(x: swipeOff)
		}
		.id("msg_\(m.id)")
		.background(
			highlightedMessageId == m.id
				? Self.accent.opacity(0.12) : Color.clear
		)
		.clipShape(RoundedRectangle(cornerRadius: 8))
		.simultaneousGesture(swipeGesture(for: m))
		.contextMenu {
			contextMenuItems(m)
		} preview: {
			contextMenuPreview(m)
		}
	}

	// MARK: – Album row

	@ViewBuilder
	private func albumRow(_ group: MessageGroup) -> some View {
		let mine = vm.isMine(group.first)
		let swipeOff = swipeOffsets[group.first.id] ?? 0
		ZStack {
			if swipeOff >= 0 {
				replyIconView(offset: swipeOff).padding(.leading, 16)
					.frame(maxWidth: .infinity, alignment: .leading)
			} else {
				replyIconView(offset: swipeOff).padding(.trailing, 16)
					.frame(maxWidth: .infinity, alignment: .trailing)
			}
			HStack(alignment: .bottom, spacing: 6) {
				if mine { Spacer(minLength: 52) }
				VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
					if !mine && vm.isGroup {
						Text(senderName(group.first))
							.font(.caption.bold())
							.foregroundStyle(nameColor(userId: group.first.userId ?? 0))
							.padding(.leading, 2)
					}
					albumGrid(group.messages, mine: mine)
					if let last = group.messages.last {
						timeRow(last, mine: mine, pending: vm.isPending(last))
							.padding(.horizontal, 4)
					}
					albumReactions(group.first)
				}
				if !mine { Spacer(minLength: 52) }
			}
			.padding(.horizontal, 10).padding(.vertical, 2)
			.contentShape(Rectangle())
			.offset(x: swipeOff)
		}
		.id("msg_\(group.first.id)")
		.simultaneousGesture(swipeGesture(for: group.first))
	}

	private func replyIconView(offset: CGFloat) -> some View {
		let progress = min(1.0, abs(offset) / 50.0)
		return ZStack {
			Circle().fill(Color(.systemFill))
				.frame(width: 32, height: 32)
			Image(systemName: "arrowshape.turn.up.left.fill")
				.font(.system(size: 13, weight: .bold))
				.foregroundStyle(Self.accent)
		}
		.scaleEffect(progress < 0.01 ? 0.01 : min(1.15, progress * 1.4))
		.opacity(Double(min(1.0, progress * 1.6)))
		.animation(.spring(response: 0.2, dampingFraction: 0.6), value: offset)
	}

	// MARK: – Album grid

	@ViewBuilder
	private func albumGrid(_ msgs: [ChatMessage], mine: Bool) -> some View {
		let count = msgs.count
		let cols: Int  = count <= 2 ? 2 : 3
		let size: CGFloat = count <= 2 ? 118 : 78
		let gap:  CGFloat = 2

		let chunked = stride(from: 0, to: count, by: cols).map {
			Array(msgs[$0 ..< min($0 + cols, count)])
		}

		VStack(spacing: gap) {
			ForEach(Array(chunked.enumerated()), id: \.offset) { _, rowMsgs in
				HStack(spacing: gap) {
					ForEach(rowMsgs) { m in
						if m.mediaId != nil {
							AlbumThumbView(m: m, size: size, vm: vm) {
								if let mid = m.mediaId,
								   let idx = vm.allMediaItems.firstIndex(where: { $0.id == mid }) {
									galleryStartIndex = idx
								}
							}
							.contextMenu {
								contextMenuItems(m)
							} preview: {
								contextMenuPreview(m)
							}
						}
					}
					if rowMsgs.count < cols {
						ForEach(0 ..< (cols - rowMsgs.count), id: \.self) { _ in
							Color.clear.frame(width: size, height: size)
						}
					}
				}
			}
		}
		.clipShape(RoundedRectangle(cornerRadius: 14))
		.shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
	}

	// Compact time row for album groups (no per-message read receipts)
	private func timeRow(_ m: ChatMessage, mine: Bool, pending: Bool) -> some View {
		HStack(spacing: 3) {
			Text(timeStr(m.createdAt))
				.font(.system(size: 10))
				.foregroundStyle(mine ? .white.opacity(0.6) : .secondary)
			if m.editedAt != nil {
				Text("ред.").font(.system(size: 9))
					.foregroundStyle(mine ? .white.opacity(0.45) : .secondary)
			}
			if mine && pending {
				Image(systemName: "clock")
					.font(.system(size: 9, weight: .semibold))
					.foregroundStyle(.white.opacity(0.45))
			}
		}
	}

	// Reactions for album rows (mirrors MessageBubbleView.reactionsRow)
	@ViewBuilder
	private func albumReactions(_ m: ChatMessage) -> some View {
		if let reactions = m.reactions, !reactions.isEmpty {
			HStack(spacing: 4) {
				ForEach(reactions, id: \.emoji) { r in
					let isMine = r.userIds?.contains(vm.currentUserId ?? -1) ?? false
					Button { Task { await vm.toggleReaction(r.emoji, on: m) } } label: {
						HStack(spacing: 2) {
							Text(r.emoji).font(.system(size: 13))
							if r.count > 1 {
								Text("\(r.count)").font(.system(size: 10, weight: .semibold))
									.foregroundStyle(isMine ? .white : .primary)
							}
						}
						.padding(.horizontal, 8).padding(.vertical, 4)
						.background(isMine ? AnyShapeStyle(Self.accent) : AnyShapeStyle(Color(.secondarySystemBackground)))
						.clipShape(Capsule())
					}
				}
			}
		}
	}

	// MARK: – Context menu

	@ViewBuilder
	private func contextMenuItems(_ m: ChatMessage) -> some View {
		if !m.isDeleted {
			Button { vm.replyingTo = m } label: { Label("Ответить",   systemImage: "arrowshape.turn.up.left") }
			Button { messageForReaction = m } label: { Label("Реакция", systemImage: "face.smiling") }
			Button { vm.messageToForward = m } label: { Label("Переслать", systemImage: "arrowshape.turn.up.right") }
			if m.text != nil {
				Button { UIPasteboard.general.string = m.text ?? "" } label: { Label("Копировать", systemImage: "doc.on.doc") }
			}
			if m.editedAt != nil {
				Button { historyMessageId = m.id } label: {
					Label("История изменений", systemImage: "clock.arrow.circlepath")
				}
			}
			if !vm.isGroup || isMyChatAdmin {
				if vm.pinnedMessage?.id == m.id {
					Button { Task { await unpinMessage() } } label: {
						Label("Открепить", systemImage: "pin.slash")
					}
				} else {
					Button { Task { await pinMessage(m) } } label: {
						Label("Закрепить", systemImage: "pin")
					}
				}
			}
			if vm.isMine(m) && !vm.isPending(m) && m.text != nil {
				Button { editText = m.text ?? ""; editingMessage = m } label: { Label("Редактировать", systemImage: "pencil") }
			}
			Divider()
			Button(role: .destructive) {
				deleteTarget = m
				deleteCanForEveryone = vm.isMine(m) && !vm.isPending(m)
			} label: {
				Label("Удалить", systemImage: "trash")
			}
		}
	}

	// MARK: – Context menu preview (shown when long-pressing, no transforms applied)

	@ViewBuilder
	private func contextMenuPreview(_ m: ChatMessage) -> some View {
		let mine = vm.isMine(m)
		Group {
			if m.isDeleted {
				HStack(spacing: 5) {
					Image(systemName: "trash").font(.system(size: 12))
					Text("Сообщение удалено").font(.system(size: 14))
				}
				.foregroundStyle(Color(.tertiaryLabel))
				.padding(.horizontal, 14).padding(.vertical, 10)
				.background(Color(.systemFill))
				.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
			} else {
				VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
					if let text = m.text, !text.isEmpty {
						Text(text)
							.font(.system(size: 15))
							.foregroundStyle(mine ? .white : .primary)
							.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
					} else if let type = m.mediaType {
						HStack(spacing: 6) {
							Image(systemName: mediaTypeIcon(type)).font(.system(size: 15))
							Text(mediaTypeLabel(type)).font(.system(size: 14))
						}
						.foregroundStyle(mine ? .white.opacity(0.85) : Color(.secondaryLabel))
						.padding(.horizontal, 12).padding(.vertical, 8)
					}
					Text(timeStr(m.createdAt))
						.font(.system(size: 10))
						.foregroundStyle(mine ? .white.opacity(0.55) : Color(.tertiaryLabel))
						.padding(.horizontal, 12).padding(.bottom, 6)
				}
				.background(mine ? AnyShapeStyle(Self.mineGrad) : AnyShapeStyle(Color(.secondarySystemBackground)))
				.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
			}
		}
		.padding(10)
	}

	private func mediaTypeIcon(_ type: String) -> String {
		switch type {
		case "image": return "photo"
		case "video", "video_note": return "video"
		case "voice": return "waveform"
		case "audio": return "music.note"
		default: return "doc"
		}
	}

	private func mediaTypeLabel(_ type: String) -> String {
		switch type {
		case "image": return "Фото"
		case "video": return "Видео"
		case "video_note": return "Видеосообщение"
		case "voice": return "Голосовое"
		case "audio": return "Аудио"
		default: return "Файл"
		}
	}

	// MARK: – Swipe gesture

	private func swipeGesture(for m: ChatMessage) -> some Gesture {
		DragGesture(minimumDistance: 30, coordinateSpace: .local)
			.onChanged { v in
				let h = v.translation.width
				let y = v.translation.height
				guard abs(h) > abs(y) * 1.8 else {
					swipeOffsets[m.id] = 0
					return
				}
				swipeOffsets[m.id] = h > 0 ? min(56, h) : max(-56, h)
			}
			.onEnded { v in
				let h = v.translation.width
				let y = v.translation.height
				if abs(h) > 52, abs(h) > abs(y) * 1.5 {
					vm.replyingTo = m
					UIImpactFeedbackGenerator(style: .light).impactOccurred()
				}
				withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
					swipeOffsets[m.id] = 0
				}
			}
	}

	// MARK: – Mention bar

	@ViewBuilder
	private var mentionBar: some View {
		if !vm.mentionSuggestions.isEmpty {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					ForEach(vm.mentionSuggestions) { member in
						Button {
							vm.insertMention(member)
							UIImpactFeedbackGenerator(style: .light).impactOccurred()
						} label: {
							HStack(spacing: 6) {
								Circle().fill(nameColor(userId: member.userId))
									.overlay(Text(String(member.user.nickname.prefix(1)).uppercased())
										.font(.caption2.bold()).foregroundStyle(.white))
									.frame(width: 26, height: 26)
								Text(member.user.nickname).font(.subheadline.bold())
							}
							.padding(.horizontal, 10).padding(.vertical, 5)
							.background(Color(.secondarySystemBackground))
							.clipShape(Capsule())
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal, 12)
			}
			.frame(height: 44)
			.background(.ultraThinMaterial)
			.overlay(Divider(), alignment: .top)
		}
	}

	// MARK: – Reply bar

	@ViewBuilder
	private var replyBar: some View {
		if let reply = vm.replyingTo {
			HStack(spacing: 8) {
				Image(systemName: "arrowshape.turn.up.left.fill")
					.font(.system(size: 13))
					.foregroundStyle(Self.accent)
				Rectangle().fill(Self.accent)
					.frame(width: 2, height: 30)
					.clipShape(Capsule())
				VStack(alignment: .leading, spacing: 1) {
					Text(senderName(reply))
						.font(.caption.bold())
						.foregroundStyle(Self.accent)
						.lineLimit(1)
					Text(reply.text ?? "Медиа")
						.font(.caption)
						.foregroundStyle(.secondary)
						.lineLimit(1)
				}
				Spacer(minLength: 0)
				Button { withAnimation { vm.replyingTo = nil } } label: {
					Image(systemName: "xmark")
						.font(.system(size: 11, weight: .heavy))
						.foregroundStyle(Self.accent)
						.frame(width: 26, height: 26)
						.background(Circle().fill(Self.accent.opacity(0.12)))
				}
			}
			.padding(.horizontal, 12)
			.frame(height: 44)
			.background(Color(.systemBackground))
			.overlay(Divider(), alignment: .top)
			.transition(.move(edge: .bottom).combined(with: .opacity))
		}
	}

	// MARK: – Scroll FAB

	private func scrollFAB(proxy: ScrollViewProxy) -> some View {
		Button {
			proxy.scrollTo("__bottom__", anchor: .bottom)
			vm.setAtBottom(true)
		} label: {
			ZStack(alignment: .topTrailing) {
				Circle().fill(.ultraThinMaterial).frame(width: 38, height: 38)
					.shadow(color: .black.opacity(0.15), radius: 4)
				Image(systemName: "chevron.down")
					.font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
					.frame(width: 38, height: 38)
				if vm.newMessagesBelowCount > 0 {
					Text("\(vm.newMessagesBelowCount)")
						.font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
						.padding(.horizontal, 4).padding(.vertical, 2)
						.background(Self.accent).clipShape(Capsule())
						.offset(x: 6, y: -4)
				}
			}
		}
	}

	// MARK: – Error toast

	@ViewBuilder
	private var errorToast: some View {
		if let err = vm.error {
			HStack(spacing: 8) {
				Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.white)
				Text(err).font(.footnote).foregroundStyle(.white).lineLimit(2)
				Spacer()
				Button { vm.error = nil } label: {
					Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(.white.opacity(0.8))
				}
			}
			.padding(12)
			.background(Color.red.opacity(0.92))
			.clipShape(RoundedRectangle(cornerRadius: 12))
			.padding(.horizontal, 16).padding(.top, 8)
			.shadow(radius: 4).zIndex(100)
			.transition(.move(edge: .top).combined(with: .opacity))
			.onAppear {
				Task { try? await Task.sleep(nanoseconds: UIConstants.errorToastAutoDismissSec.seconds_ns); withAnimation { vm.error = nil } }
			}
		}
	}

	// MARK: – Edit sheet

	private func editSheet(_ m: ChatMessage) -> some View {
		NavigationStack {
			TextEditor(text: $editText).padding(8)
				.navigationTitle("Редактировать").navigationBarTitleDisplayMode(.inline)
				.toolbar {
					ToolbarItem(placement: .cancellationAction) { Button("Отмена") { editingMessage = nil } }
					ToolbarItem(placement: .confirmationAction) {
						Button("Сохранить") {
							Task { await vm.editMessage(m, newText: editText); editingMessage = nil }
						}
						.disabled(editText.trimmingCharacters(in: .whitespaces).isEmpty)
					}
				}
				.onAppear { editText = m.text ?? "" }
		}
	}

	// MARK: – Helpers

	private func scrollToMessage(_ id: Int, proxy: ScrollViewProxy) {
		withAnimation(.easeInOut(duration: 0.3)) {
			proxy.scrollTo("msg_\(id)", anchor: .center)
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + UIConstants.scrollToMessageDelay) {
			withAnimation(.easeIn(duration: 0.15)) { highlightedMessageId = id }
			DispatchQueue.main.asyncAfter(deadline: .now() + UIConstants.messageHighlightDuration) {
				withAnimation(.easeOut(duration: 0.3)) { highlightedMessageId = nil }
			}
		}
	}

	private func senderName(_ m: ChatMessage) -> String {
		if let nick = vm.chatMembers.first(where: { $0.userId == m.userId })?.user.nickname {
			return nick
		}
		if m.userId != vm.currentUserId { return vm.title }
		return "User \(m.userId ?? 0)"
	}

	private func nameColor(userId: Int) -> Color {
		let palette: [Color] = [.blue, .purple, .orange, .pink, .green, .teal, .indigo, .cyan]
		return palette[abs(userId) % palette.count]
	}

	private func timeStr(_ iso: String?) -> String {
		guard let iso else { return "" }
		if let d = Self.isoFull.date(from: iso) { return Self.timeFmt.string(from: d) }
		if let d = ISO8601DateFormatter().date(from: iso) { return Self.timeFmt.string(from: d) }
		return ""
	}

	// MARK: – Album grouping

	private func buildGroups(_ messages: [ChatMessage]) -> [MessageGroup] {
		func isAlbumItem(_ m: ChatMessage) -> Bool {
			let t = m.mediaType
			let isMedia = (t == "image" || t == "video" || t == "video_note")
			return isMedia && !m.isDeleted
				&& m.text == nil && m.mediaId != nil && m.mediaId != "pending"
		}

		var result: [MessageGroup] = []
		var i = 0
		while i < messages.count {
			let m = messages[i]
			guard isAlbumItem(m) else {
				result.append(MessageGroup(id: m.id, messages: [m])); i += 1; continue
			}
			var group = [m]
			let base = parseEpoch(m.createdAt)
			var j = i + 1
			while j < messages.count && group.count < 9 {
				let next = messages[j]
				guard isAlbumItem(next),
				      next.userId == m.userId,
				      abs(parseEpoch(next.createdAt) - base) < 60
				else { break }
				group.append(next); j += 1
			}
			result.append(MessageGroup(id: m.id, messages: group))
			i = j
		}
		return result
	}

	private func parseEpoch(_ s: String?) -> TimeInterval {
		guard let s else { return 0 }
		return (Self.isoFull.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? Date())
			.timeIntervalSince1970
	}

	private func buildItems(_ messages: [ChatMessage]) -> [ChatItem] {
		let groups = buildGroups(messages)
		var items: [ChatItem] = []
		var lastDay: Date? = nil
		let cal = Calendar.current
		for group in groups {
			let date = Date(timeIntervalSince1970: parseEpoch(group.first.createdAt))
			let day = cal.startOfDay(for: date)
			if lastDay == nil || day > lastDay! {
				items.append(.separator(day))
				lastDay = day
			}
			items.append(.group(group))
		}
		return items
	}

	private func dateSeparatorView(_ date: Date) -> some View {
		Text(dateLabel(date))
			.font(.caption.weight(.medium))
			.foregroundStyle(.secondary)
			.padding(.horizontal, 14).padding(.vertical, 5)
			.background(.regularMaterial, in: Capsule())
			.frame(maxWidth: .infinity)
			.padding(.vertical, 6)
	}

	private func dateLabel(_ date: Date) -> String {
		let cal = Calendar.current
		if cal.isDateInToday(date) { return "Сегодня" }
		if cal.isDateInYesterday(date) { return "Вчера" }
		let fmt = DateFormatter()
		fmt.locale = Locale(identifier: "ru_RU")
		fmt.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: Date())
			? "d MMMM" : "d MMMM yyyy"
		return fmt.string(from: date)
	}
}

// MARK: – URL Identifiable

extension URL: @retroactive Identifiable {
	public var id: String { absoluteString }
}
