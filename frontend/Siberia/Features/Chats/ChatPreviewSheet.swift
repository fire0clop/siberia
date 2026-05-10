import Combine
import SwiftUI

// MARK: – ChatPreviewViewModel

@MainActor
final class ChatPreviewViewModel: ObservableObject {
	@Published var messages: [ChatMessage] = []
	@Published var isLoading = false

	let chatId: Int
	let currentUserId: Int?

	init(chatId: Int, currentUserId: Int?) {
		self.chatId = chatId
		self.currentUserId = currentUserId
	}

	func load() async {
		let cached = ChatCacheService.shared.loadMessages(chatId: chatId)
		if !cached.isEmpty {
			messages = cached.sorted { $0.id < $1.id }
		}
		isLoading = true
		defer { isLoading = false }
		if let batch = try? await ChatService.shared.messages(chatId: chatId, limit: 40) {
			messages = batch.sorted { $0.id < $1.id }
		}
	}

	func isMine(_ m: ChatMessage) -> Bool { m.userId == currentUserId }
}

// MARK: – ChatPeekOverlay

/// Full-screen overlay with a floating card in the center.
/// Tap outside the card → dismiss.
struct ChatPeekOverlay: View {
	let chat: ChatSummary
	let chatTitle: String
	let currentUserId: Int?
	let onDismiss: () -> Void
	let onOpen: () -> Void

	@StateObject private var vm: ChatPreviewViewModel
	@State private var appeared = false

	init(
		chat: ChatSummary,
		chatTitle: String,
		currentUserId: Int?,
		onDismiss: @escaping () -> Void,
		onOpen: @escaping () -> Void
	) {
		self.chat = chat
		self.chatTitle = chatTitle
		self.currentUserId = currentUserId
		self.onDismiss = onDismiss
		self.onOpen = onOpen
		_vm = StateObject(wrappedValue: ChatPreviewViewModel(chatId: chat.id, currentUserId: currentUserId))
	}

	var body: some View {
		ZStack {
			// Dimmed background — tap to dismiss
			Color.black.opacity(appeared ? 0.45 : 0)
				.ignoresSafeArea()
				.onTapGesture { dismiss() }

			// Floating card
			card
				.scaleEffect(appeared ? 1 : 0.88)
				.opacity(appeared ? 1 : 0)
		}
		.onAppear {
			withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
				appeared = true
			}
		}
		.task { await vm.load() }
	}

	// MARK: – Card

	private var card: some View {
		VStack(spacing: 0) {
			cardHeader
			Divider()
			messageList
			Divider()
			openButton
		}
		.frame(width: UIScreen.main.bounds.width * 0.88,
		       height: UIScreen.main.bounds.height * 0.58)
		.background(.regularMaterial)
		.clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
		.shadow(color: .black.opacity(0.3), radius: 32, y: 12)
		// Absorb taps so they don't fall through to dismiss layer
		.onTapGesture {}
	}

	private var cardHeader: some View {
		HStack {
			Text(chatTitle)
				.font(.system(size: 16, weight: .semibold))
				.lineLimit(1)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 13)
	}

	private var openButton: some View {
		Button {
			dismiss()
			onOpen()
		} label: {
			Text("Открыть чат")
				.font(.system(size: 15, weight: .medium))
				.foregroundStyle(Color.accentColor)
				.frame(maxWidth: .infinity)
				.padding(.vertical, 13)
		}
	}

	// MARK: – Message list

	private var messageList: some View {
		Group {
			if vm.isLoading && vm.messages.isEmpty {
				ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if vm.messages.isEmpty {
				Text("Нет сообщений")
					.foregroundStyle(.secondary)
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else {
				ScrollViewReader { proxy in
					ScrollView {
						LazyVStack(spacing: 2) {
							ForEach(vm.messages) { msg in
								PeekBubbleRow(message: msg, isMine: vm.isMine(msg))
									.id(msg.id)
							}
						}
						.padding(.vertical, 8)
					}
					.onAppear {
						if let last = vm.messages.last {
							proxy.scrollTo(last.id, anchor: .bottom)
						}
					}
					.onChange(of: vm.messages.count) { _, _ in
						if let last = vm.messages.last {
							withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
						}
					}
				}
			}
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	// MARK: – Dismiss

	private func dismiss() {
		withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
			appeared = false
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
			onDismiss()
		}
	}
}

// MARK: – PeekBubbleRow

private struct PeekBubbleRow: View {
	let message: ChatMessage
	let isMine: Bool

	private static let timeFmt: DateFormatter = {
		let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
	}()

	var body: some View {
		HStack {
			if isMine  { Spacer(minLength: 56) }
			content
			if !isMine { Spacer(minLength: 56) }
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 1)
	}

	@ViewBuilder
	private var content: some View {
		if message.isSystem {
			systemPill
		} else if message.isDeleted {
			deletedPill
		} else if isMine {
			bubble.background(mineGradient).clipShape(bubbleShape)
		} else {
			bubble.background(Color(.secondarySystemGroupedBackground)).clipShape(bubbleShape)
		}
	}

	private var bubble: some View {
		VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
			if let text = message.text, !text.isEmpty {
				Text(text)
					.font(.system(size: 14))
					.foregroundStyle(isMine ? .white : .primary)
					.padding(.horizontal, 10)
					.padding(.top, 7)
					.padding(.bottom, 2)
					.multilineTextAlignment(.leading)
			} else if let type = message.mediaType {
				HStack(spacing: 5) {
					Image(systemName: mediaIcon(type)).font(.system(size: 13))
					Text(mediaLabel(type)).font(.system(size: 13))
				}
				.foregroundStyle(isMine ? .white.opacity(0.85) : Color(.secondaryLabel))
				.padding(.horizontal, 10)
				.padding(.vertical, 7)
			}

			Text(formattedTime(message.createdAt))
				.font(.system(size: 10))
				.foregroundStyle(isMine ? .white.opacity(0.55) : Color(.tertiaryLabel))
				.padding(.horizontal, 10)
				.padding(.bottom, 5)
		}
	}

	private var systemPill: some View {
		Text(message.text ?? "")
			.font(.caption)
			.foregroundStyle(.secondary)
			.padding(.horizontal, 10)
			.padding(.vertical, 4)
			.background(.regularMaterial)
			.clipShape(Capsule())
			.frame(maxWidth: .infinity)
	}

	private var deletedPill: some View {
		HStack(spacing: 4) {
			Image(systemName: "trash").font(.system(size: 11))
			Text("Сообщение удалено").font(.system(size: 13))
		}
		.foregroundStyle(Color(.tertiaryLabel))
		.padding(.horizontal, 10)
		.padding(.vertical, 6)
		.background(Color(.systemFill))
		.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
	}

	private var bubbleShape: RoundedRectangle {
		RoundedRectangle(cornerRadius: 15, style: .continuous)
	}

	private var mineGradient: LinearGradient {
		LinearGradient(
			colors: [
				Color(red: 0.357, green: 0.553, blue: 0.937),
				Color(red: 0.169, green: 0.357, blue: 0.843),
			],
			startPoint: .topLeading, endPoint: .bottomTrailing
		)
	}

	private func mediaIcon(_ type: String) -> String {
		switch type {
		case "image":      return "photo"
		case "video", "video_note": return "video"
		case "voice":      return "waveform"
		case "audio":      return "music.note"
		case "document":   return "doc"
		default:           return "paperclip"
		}
	}

	private func mediaLabel(_ type: String) -> String {
		switch type {
		case "image":      return "Фото"
		case "video":      return "Видео"
		case "video_note": return "Видеосообщение"
		case "voice":      return "Голосовое"
		case "audio":      return "Аудио"
		case "document":   return "Файл"
		default:           return "Вложение"
		}
	}

	private func formattedTime(_ iso: String?) -> String {
		guard let s = iso else { return "" }
		var f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		if let d = f.date(from: s) { return Self.timeFmt.string(from: d) }
		f.formatOptions = [.withInternetDateTime]
		if let d = f.date(from: s) { return Self.timeFmt.string(from: d) }
		return ""
	}
}
