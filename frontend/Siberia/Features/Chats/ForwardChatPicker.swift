import SwiftUI

struct ForwardChatPicker: View {

	let onSelect: (ChatSummary) -> Void
	@Environment(\.dismiss) private var dismiss
	@EnvironmentObject private var appState: AppState

	@State private var chats: [ChatSummary] = []
	@State private var memberNames: [Int: String] = [:]
	@State private var memberAvatars: [Int: String] = [:]
	@State private var isLoading = true
	@State private var searchText = ""

	private var filtered: [ChatSummary] {
		guard !searchText.isEmpty else { return chats }
		let q = searchText.lowercased()
		return chats.filter { resolvedTitle($0).lowercased().contains(q) }
	}

	var body: some View {
		NavigationStack {
			Group {
				if isLoading {
					ProgressView()
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if filtered.isEmpty {
					ContentUnavailableView.search(text: searchText)
				} else {
					chatList
				}
			}
			.background(Color(.systemGroupedBackground))
			.navigationTitle("Переслать в…")
			.navigationBarTitleDisplayMode(.inline)
			.searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск")
			.toolbar {
				ToolbarItem(placement: .cancellationAction) {
					Button("Отмена") { dismiss() }
				}
			}
		}
		.task { await loadChats() }
	}

	// MARK: – List

	private var chatList: some View {
		List {
			ForEach(filtered) { chat in
				Button {
					onSelect(chat)
					dismiss()
				} label: {
					chatRow(chat)
				}
				.buttonStyle(.plain)
				.listRowBackground(Color(.secondarySystemGroupedBackground))
				.listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
			}
		}
		.listStyle(.insetGrouped)
		.scrollContentBackground(.hidden)
	}

	@ViewBuilder
	private func chatRow(_ chat: ChatSummary) -> some View {
		let title = resolvedTitle(chat)
		let (c1, c2) = paletteColors(for: title)

		HStack(spacing: 12) {
			// Avatar
			ZStack {
				Circle()
					.fill(LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing))
				if let urlStr = memberAvatars[chat.id], let url = URL(string: urlStr) {
					AsyncImage(url: url) { phase in
						if case .success(let img) = phase {
							img.resizable().scaledToFill().clipShape(Circle())
						} else {
							initialsLabel(title)
						}
					}
				} else {
					initialsLabel(title)
				}
			}
			.frame(width: 46, height: 46)

			// Text
			VStack(alignment: .leading, spacing: 3) {
				Text(title)
					.font(.system(size: 15, weight: .semibold))
					.lineLimit(1)
				if let preview = chat.displayText, !preview.isEmpty {
					Text(preview)
						.font(.system(size: 13))
						.foregroundStyle(.secondary)
						.lineLimit(1)
				} else {
					Text(chat.type == "group" ? "Группа" : chat.type == "channel" ? "Канал" : "Личные сообщения")
						.font(.system(size: 13))
						.foregroundStyle(.tertiary)
				}
			}

			Spacer()

			Image(systemName: "arrow.turn.up.right")
				.font(.system(size: 13, weight: .medium))
				.foregroundStyle(Color(.tertiaryLabel))
		}
		.padding(.vertical, 2)
	}

	private func initialsLabel(_ title: String) -> some View {
		Text(String(title.prefix(1)).uppercased())
			.font(.system(size: 18, weight: .semibold))
			.foregroundStyle(.white)
	}

	// MARK: – Data

	private func loadChats() async {
		// Load from cache immediately
		chats = ChatCacheService.shared.loadChats()
		let cached = ChatCacheService.shared.loadMemberInfo()
		memberNames  = cached.names
		memberAvatars = cached.avatars

		do {
			chats = try await ChatService.shared.listChats()
			await resolveMemberNames()
		} catch {}
		isLoading = false
	}

	private func resolveMemberNames() async {
		let myId = appState.currentUser?.id
		let need = chats.filter { ($0.title ?? "").isEmpty }
		await withTaskGroup(of: (Int, String?, String?)?.self) { group in
			for chat in need {
				group.addTask {
					guard let members = try? await ChatService.shared.members(chatId: chat.id) else { return nil }
					let partner = members.first(where: { $0.userId != myId })
					return (chat.id, partner?.user.nickname, partner?.user.avatarUrl)
				}
			}
			for await result in group {
				if let (id, name, _) = result, let name {
					memberNames[id] = name
				}
			}
		}
	}

	// MARK: – Helpers

	private func resolvedTitle(_ c: ChatSummary) -> String {
		if let t = c.title, !t.isEmpty { return t }
		return memberNames[c.id] ?? "Чат \(c.id)"
	}

	private func paletteColors(for title: String) -> (Color, Color) {
		let table: [(String, String)] = [
			("5B8DEF","2B5BD7"), ("B48EFF","7C3AED"), ("FB923C","EA580C"),
			("F472B6","BE185D"), ("34D399","059669"), ("22D3EE","0E7490"), ("FBBF24","D97706"),
		]
		let i = abs(title.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % table.count
		let hex = { (h: String) -> Color in
			var val: UInt64 = 0
			Scanner(string: h).scanHexInt64(&val)
			return Color(
				red:   Double((val >> 16) & 0xFF) / 255,
				green: Double((val >> 8)  & 0xFF) / 255,
				blue:  Double( val        & 0xFF) / 255
			)
		}
		return (hex(table[i].0), hex(table[i].1))
	}
}
