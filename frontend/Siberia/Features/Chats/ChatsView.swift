import SwiftUI

// MARK: – ChatsView

struct ChatsView: View {

	@EnvironmentObject private var appState: AppState
	@Environment(\.scenePhase) private var scenePhase

	@State private var chats:         [ChatSummary]      = []
	@State private var memberNames:   [Int: String]      = [:]
	@State private var memberAvatars: [Int: String]      = [:]
	/// chatId → partnerUserId (только для DM-чатов, members.count == 2).
	/// Используется для вывода зелёной точки онлайн на аватарке.
	@State private var memberPartnerIds: [Int: Int]      = [:]
	@State private var lastMessages:  [Int: ChatMessage] = [:]
	@State private var error:         String?
	@State private var isLoading    = false
	@State private var showNewChat      = false
	@State private var showChannelSearch = false
	@State private var showGlobalSearch = false
	@State private var pendingChatRoute: ChatRoute?
	@State private var searchText   = ""
	@State private var navPath      = NavigationPath()
	@State private var previewChat: ChatSummary? = nil

	// MARK: – Formatters

	private static let timeFmt: DateFormatter = {
		let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
	}()
	private static let shortDateFmt: DateFormatter = {
		let f = DateFormatter()
		f.locale = Locale(identifier: "ru_RU")
		f.dateFormat = "d MMM"
		return f
	}()

	private static func parseISO(_ s: String) -> Date? {
		for opts: ISO8601DateFormatter.Options in [
			[.withInternetDateTime, .withFractionalSeconds],
			[.withInternetDateTime],
		] {
			let f = ISO8601DateFormatter(); f.formatOptions = opts
			if let d = f.date(from: s) { return d }
		}
		let df = DateFormatter()
		df.locale = Locale(identifier: "en_US_POSIX")
		for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ssZZZZZ"] {
			df.dateFormat = fmt
			if let d = df.date(from: s) { return d }
		}
		return nil
	}

	// MARK: – Derived

	private var baseChats: [ChatSummary] {
		// Раньше отфильтровывали чаты без сообщений — но это значит что только что
		// созданный чат не виден до отправки первого сообщения. Теперь показываем все.
		chats
	}

	private var visibleChats: [ChatSummary] {
		guard !searchText.isEmpty else { return baseChats }
		let q = searchText.lowercased()
		return baseChats.filter {
			resolvedTitle($0).lowercased().contains(q) ||
			($0.displayText ?? "").lowercased().contains(q)
		}
	}

	// MARK: – Body

	var body: some View {
		NavigationStack(path: $navPath) {
			Group {
				if isLoading && chats.isEmpty {
					ChatsSkeletonView()
				} else if !searchText.isEmpty && visibleChats.isEmpty {
					ContentUnavailableView.search(text: searchText)
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if baseChats.isEmpty {
					emptyStateView
				} else {
					chatList
				}
			}
			.navigationTitle("Сообщения")
			.searchable(
				text: $searchText,
				placement: .navigationBarDrawer(displayMode: .always),
				prompt: "Поиск"
			)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button { showGlobalSearch = true } label: {
						Image(systemName: "magnifyingglass")
							.font(.system(size: 16, weight: .semibold))
					}
				}
				ToolbarItem(placement: .topBarTrailing) {
					Menu {
						Button {
							showNewChat = true
						} label: {
							Label("Новый чат / группа", systemImage: "square.and.pencil")
						}
						Button {
							showChannelSearch = true
						} label: {
							Label("Найти канал", systemImage: "megaphone")
						}
					} label: {
						Image(systemName: "square.and.pencil")
							.font(.system(size: 17, weight: .semibold))
					}
				}
			}
			.navigationDestination(for: ChatRoute.self) { ChatDetailView(route: $0) }
			.alert("Ошибка", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) { error = nil }
			} message: { Text(error ?? "") }
			.sheet(isPresented: $showNewChat, onDismiss: {
				Task { await load() }
				if let route = pendingChatRoute {
					navPath.append(route)
					pendingChatRoute = nil
				}
			}) {
				NewChatSheet(myId: appState.currentUser?.id) { route in
					pendingChatRoute = route
				}
			}
			.sheet(isPresented: $showChannelSearch, onDismiss: {
				Task { await load() }
				if let route = pendingChatRoute {
					navPath.append(route)
					pendingChatRoute = nil
				}
			}) {
				ChannelSearchView { route in pendingChatRoute = route }
			}
			.sheet(isPresented: $showGlobalSearch, onDismiss: {
				if let route = pendingChatRoute {
					navPath.append(route)
					pendingChatRoute = nil
				}
			}) {
				GlobalSearchView { route in pendingChatRoute = route }
			}
		}
		.task { await load() }
		.onChange(of: scenePhase) { _, p in if p == .active { Task { await load() } } }
		// Когда профиль наконец-то догрузится — перезапускаем loadMemberNames чтобы перебрать
		// названия чатов с правильным myId (иначе они остаются нашим ником).
		.onChange(of: appState.currentUser?.id) { _, _ in
			Task { await loadMemberNames() }
		}
		.onReceive(NotificationCenter.default.publisher(for: .siberiaChatsShouldReload)) { _ in
			Task { await load() }
		}
		.overlay {
			if let chat = previewChat {
				ChatPeekOverlay(
					chat: chat,
					chatTitle: resolvedTitle(chat),
					currentUserId: appState.currentUser?.id,
					onDismiss: { previewChat = nil },
					onOpen: {
						navPath.append(ChatRoute(chatId: chat.id, title: resolvedTitle(chat), syncSeq: chat.syncSeq))
					}
				)
				.transition(.opacity)
			}
		}
		.animation(.easeInOut(duration: 0.15), value: previewChat?.id)
	}

	// MARK: – Chat list

	private var chatList: some View {
		List {
			ForEach(visibleChats) { c in
				Button {
					navPath.append(ChatRoute(chatId: c.id, title: resolvedTitle(c), syncSeq: c.syncSeq))
				} label: {
					chatCard(c)
				}
				.buttonStyle(CardPressStyle())
				.listRowBackground(Color.clear)
				.listRowSeparator(.hidden)
				.listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
				.simultaneousGesture(
					LongPressGesture(minimumDuration: 0.45)
						.onEnded { _ in
							UIImpactFeedbackGenerator(style: .medium).impactOccurred()
							previewChat = c
						}
				)
			}
		}
		.listStyle(.plain)
		.scrollContentBackground(.hidden)
		.background(Color(.systemGroupedBackground))
		.refreshable { await load() }
	}

	// MARK: – Empty state

	private var emptyStateView: some View {
		VStack(spacing: 14) {
			Image(systemName: "bubble.left.and.bubble.right")
				.font(.system(size: 56))
				.foregroundStyle(Color.accentColor.opacity(0.2))
			Text("Нет сообщений")
				.font(.system(size: 20, weight: .semibold))
			Text("Нажмите ✏️ вверху, чтобы начать диалог")
				.font(.system(size: 15))
				.foregroundStyle(.secondary)
				.multilineTextAlignment(.center)
		}
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}

	// MARK: – Chat card

	@ViewBuilder
	private func chatCard(_ c: ChatSummary) -> some View {
		let unread = (c.unreadCount ?? 0) > 0
		let title  = resolvedTitle(c)
		let (c1, c2) = paletteColors(for: title)
		let grad = LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)

		HStack(spacing: 0) {

			// ── Per-chat color identity bar ──
			grad
				.opacity(unread ? 1 : 0.4)
				.frame(width: 4)
				.clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
				.padding(.vertical, 16)

			// ── Avatar with gradient ring ──
			ZStack(alignment: .bottomTrailing) {
				ZStack {
					Circle()
						.strokeBorder(grad.opacity(unread ? 0.85 : 0.35), lineWidth: 2.5)
						.frame(width: 59, height: 59)
					avatarInner(c, title: title)
						.frame(width: 53, height: 53)
				}
				// Зелёная точка если собеседник по DM-чату онлайн.
				if isPartnerOnline(c) {
					Circle()
						.fill(Color(red: 0.22, green: 0.78, blue: 0.45))
						.frame(width: 14, height: 14)
						.overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2.5))
						.offset(x: 2, y: 2)
				}
			}
			.padding(.leading, 12)

			// ── Text block ──
			VStack(alignment: .leading, spacing: 5) {

				HStack(alignment: .firstTextBaseline) {
					Text(title)
						.font(.system(size: 16, weight: unread ? .bold : .semibold))
						.foregroundStyle(.primary)
						.lineLimit(1)

					Spacer(minLength: 8)

					if let d = lastMessageDate(c) {
						Text(formattedTime(d))
							.font(.system(size: 12, weight: unread ? .bold : .regular))
							.foregroundStyle(unread ? c1 : Color(.tertiaryLabel))
					}
				}

				HStack(alignment: .center, spacing: 0) {
					previewLabel(c, unread: unread)
					Spacer(minLength: 6)
					if let n = c.unreadCount, n > 0 {
						Text(n < 100 ? "\(n)" : "99+")
							.font(.system(size: 12, weight: .bold))
							.foregroundStyle(.white)
							.padding(.horizontal, 7)
							.padding(.vertical, 3)
							.background(grad)
							.clipShape(Capsule())
					}
				}
			}
			.padding(.leading, 12)
			.padding(.trailing, 16)
		}
		.padding(.vertical, 10)
		.background(Color(.secondarySystemGroupedBackground))
		.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
		.overlay {
			if unread {
				RoundedRectangle(cornerRadius: 16, style: .continuous)
					.strokeBorder(c1.opacity(0.18), lineWidth: 1)
			}
		}
		.shadow(color: .black.opacity(colorSchemeIsDark ? 0.25 : 0.07), radius: 8, y: 3)
		.contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
	}

	@Environment(\.colorScheme) private var colorScheme
	private var colorSchemeIsDark: Bool { colorScheme == .dark }

	// MARK: – Preview label

	@ViewBuilder
	private func previewLabel(_ c: ChatSummary, unread: Bool) -> some View {
		let msg  = lastMessages[c.id]
		let text = msg?.text.flatMap { $0.isEmpty ? nil : $0 }
		let isMedia = text == nil && (msg?.hasMedia ?? false)

		if let t = text {
			Text(t)
				.font(.system(size: 14, weight: unread ? .medium : .regular))
				.foregroundStyle(unread ? Color(.secondaryLabel) : Color(.tertiaryLabel))
				.lineLimit(1)
		} else if isMedia {
			HStack(spacing: 3) {
				Image(systemName: "paperclip").font(.system(size: 11))
				Text("Вложение").font(.system(size: 14))
			}
			.foregroundStyle(Color(.tertiaryLabel))
		} else if msg == nil && c.lastMessageId != nil {
			Text("…")
				.font(.system(size: 14))
				.foregroundStyle(Color(.quaternaryLabel))
		} else {
			Text("Нет сообщений")
				.font(.system(size: 14))
				.foregroundStyle(Color(.quaternaryLabel))
		}
	}

	// MARK: – Avatar

	@ViewBuilder
	private func avatarInner(_ c: ChatSummary, title: String) -> some View {
		let (c1, c2) = paletteColors(for: title)
		ZStack {
			Circle()
				.fill(LinearGradient(colors: [c1, c2],
									 startPoint: .topLeading, endPoint: .bottomTrailing))
			if let s = memberAvatars[c.id], let url = URL(string: s) {
				AsyncImage(url: url) { phase in
					if case .success(let img) = phase {
						img.resizable().scaledToFill().clipShape(Circle())
					} else { initialsLabel(title) }
				}
			} else {
				initialsLabel(title)
			}
		}
	}

	private func initialsLabel(_ title: String) -> some View {
		Text(String(title.prefix(1)).uppercased())
			.font(.system(size: 22, weight: .semibold))
			.foregroundStyle(.white)
	}

	// MARK: – Helpers

	private func resolvedTitle(_ c: ChatSummary) -> String {
		if let t = c.title, !t.isEmpty { return t }
		return memberNames[c.id] ?? "Чат \(c.id)"
	}

	private func lastMessageDate(_ c: ChatSummary) -> Date? {
		guard let ts = lastMessages[c.id]?.createdAt ?? c.displayAt else { return nil }
		return Self.parseISO(ts)
	}

	private func formattedTime(_ date: Date) -> String {
		let cal = Calendar.current
		if cal.isDateInToday(date)     { return Self.timeFmt.string(from: date) }
		if cal.isDateInYesterday(date) { return "Вчера" }
		return Self.shortDateFmt.string(from: date)
	}

	private func paletteColors(for title: String) -> (Color, Color) {
		let table: [(String, String)] = [
			("5B8DEF","2B5BD7"), ("B48EFF","7C3AED"), ("FB923C","EA580C"),
			("F472B6","BE185D"), ("34D399","059669"), ("22D3EE","0E7490"), ("FBBF24","D97706"),
		]
		let i = abs(title.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % table.count
		return (Color(hex: table[i].0), Color(hex: table[i].1))
	}

	// MARK: – Data loading

	private func load() async {
		// Show cached data instantly while network loads
		if chats.isEmpty {
			chats        = ChatCacheService.shared.loadChats()
			lastMessages = ChatCacheService.shared.loadLastMessages()
			let cached   = ChatCacheService.shared.loadMemberInfo()
			memberNames  = cached.names
			memberAvatars = cached.avatars
		}

		isLoading = true; error = nil
		defer { isLoading = false }
		do {
			chats = try await ChatService.shared.listChats()
			async let m: () = loadMemberNames()
			async let l: () = loadLastMessages()
			await m; await l
			// Persist for next launch
			ChatCacheService.shared.saveChats(chats)
			ChatCacheService.shared.saveLastMessages(lastMessages)
			ChatCacheService.shared.saveMemberInfo(names: memberNames, avatars: memberAvatars)
		} catch {
			self.error = error.localizedDescription
		}
	}

	private func loadMemberNames() async {
		// КРИТИЧНО: ждём чтобы appState.currentUser был загружен.
		// Иначе myId=nil → фильтр `$0.user.id != nil` всегда true → берётся
		// первый член чата (часто это мы сами), и в списке чат подписан нашим именем.
		var myId = appState.currentUser?.id
		if myId == nil {
			// Догружаем профиль если AppState ещё не успел
			if let me = try? await UserService.shared.me() {
				appState.currentUser = me
				myId = me.id
			}
		}
		guard let myId else { return }   // без id всё равно нельзя — лучше пропустить

		let need = chats.filter { ($0.title ?? "").isEmpty }
		guard !need.isEmpty else { return }

		// Возвращаем (chatId, name, avatar, partnerUserId?)
		// partnerUserId нужен чтобы дальше параллельно подтянуть presence для DM-чатов.
		var partnerIds: [Int] = []
		await withTaskGroup(of: (Int, String?, String?, Int?).self) { g in
			for c in need {
				g.addTask {
					guard let m = try? await ChatService.shared.members(chatId: c.id) else {
						return (c.id, nil, nil, nil)
					}
					let other = m.first { $0.user.id != myId }
					let partner = (m.count == 2) ? other?.user.id : nil
					return (c.id, other?.user.nickname, other?.user.avatarUrl, partner)
				}
			}
			for await (id, name, avatar, pid) in g {
				if let name   { memberNames[id]   = name }
				if let avatar { memberAvatars[id] = avatar }
				if let pid    {
					memberPartnerIds[id] = pid
					partnerIds.append(pid)
				}
			}
		}

		// Bulk-fetch presence — чтобы зелёная точка появилась мгновенно, без ожидания WS-события.
		await fetchPresencesInBulk(partnerIds)
	}

	/// True если у чата known partner и тот сейчас в `appState.onlineUserIds`.
	private func isPartnerOnline(_ c: ChatSummary) -> Bool {
		guard let pid = memberPartnerIds[c.id] else { return false }
		return appState.onlineUserIds.contains(pid)
	}

	private func fetchPresencesInBulk(_ userIds: [Int]) async {
		guard !userIds.isEmpty else { return }
		await withTaskGroup(of: (Int, Bool)?.self) { g in
			for uid in userIds {
				g.addTask {
					guard let p = try? await UserService.shared.presence(userId: uid) else { return nil }
					return (uid, p.online)
				}
			}
			for await result in g {
				guard let (uid, online) = result else { continue }
				if online {
					appState.onlineUserIds.insert(uid)
				} else {
					appState.onlineUserIds.remove(uid)
				}
			}
		}
	}

	private func loadLastMessages() async {
		let need = chats.filter { $0.lastMessageId != nil }
		await withTaskGroup(of: (Int, ChatMessage?).self) { g in
			for c in need {
				g.addTask {
					let msgs = try? await ChatService.shared.messages(chatId: c.id, limit: 1)
					return (c.id, msgs?.first)
				}
			}
			for await (id, msg) in g {
				if let msg { lastMessages[id] = msg }
			}
		}
	}
}

// MARK: – Card press style

struct RowPressStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.background(configuration.isPressed ? Color(.systemFill) : Color.clear)
	}
}

private struct CardPressStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.scaleEffect(configuration.isPressed ? 0.975 : 1)
			.opacity(configuration.isPressed ? 0.88 : 1)
			.animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
	}
}

// MARK: – Color hex

extension Color {
	init(hex: String) {
		let v = UInt64(hex, radix: 16) ?? 0
		self.init(
			red:   Double((v >> 16) & 0xFF) / 255,
			green: Double((v >>  8) & 0xFF) / 255,
			blue:  Double( v        & 0xFF) / 255
		)
	}
}

// MARK: – NewChatSheet

struct NewChatSheet: View {

	let myId: Int?
	let onChatCreated: (ChatRoute) -> Void
	@Environment(\.dismiss) private var dismiss
	@FocusState private var focused: Bool

	@State private var friends:       [User] = []
	@State private var searchResults: [User] = []
	@State private var searchText   = ""
	@State private var isSearching  = false
	@State private var busyId:       Int?
	@State private var error:        String?
	@State private var searchTask:   Task<Void, Never>?
	@State private var showCreateGroup = false
	@State private var showCreateChannel = false

	// Friends filtered by current query
	private var matchedFriends: [User] {
		guard !searchText.isEmpty else { return friends }
		let q = searchText.lowercased()
		return friends.filter { $0.nickname.lowercased().contains(q) }
	}

	// Non-friend results (deduped from friends)
	private var otherResults: [User] {
		let friendIds = Set(friends.map(\.id))
		return searchResults.filter { !friendIds.contains($0.id) && $0.id != myId }
	}

	var body: some View {
		NavigationStack {
			VStack(spacing: 0) {
				// ── Search input ──
				HStack(spacing: 10) {
					Image(systemName: "magnifyingglass")
						.font(.system(size: 15))
						.foregroundStyle(.secondary)

					TextField("Введите ник", text: $searchText)
						.font(.system(size: 16))
						.autocorrectionDisabled()
						.textInputAutocapitalization(.never)
						.focused($focused)
						.onChange(of: searchText) { _, q in scheduleSearch(q) }

					if isSearching {
						ProgressView().scaleEffect(0.75)
					} else if !searchText.isEmpty {
						Button { searchText = ""; searchResults = [] } label: {
							Image(systemName: "xmark.circle.fill")
								.foregroundStyle(.tertiary)
						}
						.buttonStyle(.plain)
					}
				}
				.padding(.horizontal, 14)
				.padding(.vertical, 11)
				.background(Color(.secondarySystemFill))
				.clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
				.padding(.horizontal, 16)
				.padding(.top, 12)
				.padding(.bottom, 10)

				Divider().opacity(0.5)

				// ── Results ──
				ScrollView {
					LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
						// Quick-actions: group / channel
						quickActionsBar
							.padding(.horizontal, 16)
							.padding(.top, 4)
							.padding(.bottom, 8)

						// Friends section
						if !matchedFriends.isEmpty {
							Section {
								ForEach(matchedFriends) { u in userRow(u, isFriend: true) }
							} header: {
								sectionHeader(searchText.isEmpty ? "Друзья" : "Друзья · совпадения")
							}
						}

						// Global search results
						if !otherResults.isEmpty {
							Section {
								ForEach(otherResults) { u in userRow(u, isFriend: false) }
							} header: {
								sectionHeader("Все пользователи")
							}
						}

						// States
						if searchText.isEmpty && friends.isEmpty {
							emptyFriendsHint
						} else if !searchText.isEmpty && !isSearching
								   && matchedFriends.isEmpty && otherResults.isEmpty {
							ContentUnavailableView.search(text: searchText)
								.padding(.top, 40)
						}
					}
					.padding(.bottom, 24)
				}
			}
			.background(Color(.systemGroupedBackground).ignoresSafeArea())
			.navigationTitle("Новый чат")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Отмена") { dismiss() }
				}
			}
			.alert("Ошибка", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) { error = nil }
			} message: { Text(error ?? "") }
			.sheet(isPresented: $showCreateGroup) {
				CreateGroupSheet { route in
					onChatCreated(route)
					dismiss()
				}
			}
			.sheet(isPresented: $showCreateChannel) {
				CreateChannelSheet { route in
					onChatCreated(route)
					dismiss()
				}
			}
		}
		.task {
			friends = (try? await FriendService.shared.getFriends()) ?? []
			focused = true
		}
	}

	// MARK: – Quick actions (Group / Channel)

	private var quickActionsBar: some View {
		HStack(spacing: 10) {
			quickActionCard(
				icon: "person.3.fill",
				title: "Группа",
				subtitle: "До 200 участников",
				gradient: LinearGradient(
					colors: [Color(red: 0.36, green: 0.45, blue: 0.95), Color(red: 0.20, green: 0.30, blue: 0.85)],
					startPoint: .topLeading, endPoint: .bottomTrailing
				)
			) { showCreateGroup = true }

			quickActionCard(
				icon: "megaphone.fill",
				title: "Канал",
				subtitle: "Публикации подписчикам",
				gradient: LinearGradient(
					colors: [Color(red: 0.96, green: 0.42, blue: 0.30), Color(red: 0.82, green: 0.20, blue: 0.55)],
					startPoint: .topLeading, endPoint: .bottomTrailing
				)
			) { showCreateChannel = true }
		}
	}

	private func quickActionCard(icon: String, title: String, subtitle: String, gradient: LinearGradient, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			VStack(alignment: .leading, spacing: 8) {
				Image(systemName: icon)
					.font(.system(size: 20, weight: .semibold))
					.foregroundStyle(.white)
				Text(title)
					.font(.system(size: 15, weight: .semibold))
					.foregroundStyle(.white)
				Text(subtitle)
					.font(.system(size: 11))
					.foregroundStyle(.white.opacity(0.85))
			}
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(12)
			.background(gradient)
			.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
			.shadow(color: .black.opacity(0.12), radius: 6, y: 3)
		}
		.buttonStyle(CardPressStyle())
	}

	// MARK: – Row

	@ViewBuilder
	private func userRow(_ user: User, isFriend: Bool) -> some View {
		let (c1, c2) = paletteColors(for: user.nickname)
		let grad = LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing)

		Button {
			guard busyId == nil else { return }
			Task { await openChat(with: user) }
		} label: {
			HStack(spacing: 0) {
				// Color bar
				grad.opacity(0.5)
					.frame(width: 4)
					.clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
					.padding(.vertical, 14)

				// Avatar
				ZStack {
					Circle().strokeBorder(grad.opacity(0.4), lineWidth: 2)
						.frame(width: 51, height: 51)
					userAvatar(user)
						.frame(width: 46, height: 46)
				}
				.padding(.leading, 12)

				// Info
				VStack(alignment: .leading, spacing: 3) {
					Text(user.nickname)
						.font(.system(size: 16, weight: .semibold))
						.foregroundStyle(.primary)
						.lineLimit(1)
					if let e = user.email {
						Text(e).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
					}
				}
				.padding(.leading, 12)

				Spacer(minLength: 8)

				Group {
					if busyId == user.id {
						ProgressView().scaleEffect(0.8)
					} else {
						Image(systemName: isFriend ? "message.fill" : "chevron.right")
							.font(.system(size: isFriend ? 13 : 12, weight: .semibold))
							.foregroundStyle(isFriend ? Color.white : Color.secondary)
							.frame(width: isFriend ? 34 : 20, height: isFriend ? 34 : 20)
							.background(isFriend ? AnyShapeStyle(grad) : AnyShapeStyle(Color.clear))
							.clipShape(Circle())
					}
				}
				.padding(.trailing, 16)
			}
			.padding(.vertical, 8)
			.background(Color(.secondarySystemGroupedBackground))
			.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
			.shadow(color: .black.opacity(0.05), radius: 5, y: 2)
			.contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
		}
		.buttonStyle(CardPressStyle())
		.padding(.horizontal, 16)
		.padding(.vertical, 4)
		.disabled(busyId != nil)
	}

	@ViewBuilder
	private func userAvatar(_ user: User) -> some View {
		let (c1, c2) = paletteColors(for: user.nickname)
		ZStack {
			Circle().fill(LinearGradient(colors: [c1, c2], startPoint: .topLeading, endPoint: .bottomTrailing))
			if let s = user.avatarUrl, let url = URL(string: s) {
				AsyncImage(url: url) { phase in
					if case .success(let img) = phase { img.resizable().scaledToFill().clipShape(Circle()) }
					else { initialsText(user.nickname) }
				}
			} else { initialsText(user.nickname) }
		}
	}

	private func initialsText(_ name: String) -> some View {
		Text(String(name.prefix(1)).uppercased())
			.font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
	}

	private var emptyFriendsHint: some View {
		VStack(spacing: 12) {
			Image(systemName: "person.2")
				.font(.system(size: 40))
				.foregroundStyle(Color.accentColor.opacity(0.25))
			Text("Начните вводить ник")
				.font(.system(size: 16, weight: .medium))
				.foregroundStyle(.secondary)
		}
		.frame(maxWidth: .infinity)
		.padding(.top, 60)
	}

	private func sectionHeader(_ text: String) -> some View {
		Text(text.uppercased())
			.font(.system(size: 11, weight: .semibold))
			.foregroundStyle(.secondary)
			.frame(maxWidth: .infinity, alignment: .leading)
			.padding(.horizontal, 20)
			.padding(.top, 16)
			.padding(.bottom, 6)
			.background(Color(.systemGroupedBackground))
	}

	// MARK: – Helpers

	private func paletteColors(for name: String) -> (Color, Color) {
		let t: [(String, String)] = [
			("5B8DEF","2B5BD7"), ("B48EFF","7C3AED"), ("FB923C","EA580C"),
			("F472B6","BE185D"), ("34D399","059669"), ("22D3EE","0E7490"), ("FBBF24","D97706"),
		]
		let i = abs(name.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % t.count
		return (Color(hex: t[i].0), Color(hex: t[i].1))
	}

	private func scheduleSearch(_ q: String) {
		searchTask?.cancel()
		let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { searchResults = []; return }
		searchTask = Task {
			try? await Task.sleep(nanoseconds: 200_000_000) // 200ms debounce
			guard !Task.isCancelled else { return }
			isSearching = true
			searchResults = (try? await UserService.shared.searchUsers(query: trimmed)) ?? []
			isSearching = false
		}
	}

	private func openChat(with user: User) async {
		busyId = user.id; defer { busyId = nil }
		do {
			let chat = try await ChatService.shared.createChat(withUserId: user.id)
			let route = ChatRoute(chatId: chat.id, title: user.nickname, syncSeq: chat.syncSeq)
			onChatCreated(route)
			dismiss()
		} catch { self.error = error.localizedDescription }
	}
}

// MARK: – Skeleton

private struct ChatsSkeletonView: View {
	@State private var on = false

	var body: some View {
		List {
			ForEach(0..<8, id: \.self) { i in
				HStack(spacing: 0) {
					// Color bar
					RoundedRectangle(cornerRadius: 2)
						.fill(Color(.systemFill))
						.frame(width: 4)
						.padding(.vertical, 16)
						.opacity(on ? 0.55 : 0.2)

					// Avatar ring + circle
					ZStack {
						Circle()
							.strokeBorder(Color(.systemFill).opacity(on ? 0.55 : 0.2), lineWidth: 2.5)
							.frame(width: 59, height: 59)
						Circle()
							.fill(Color(.systemFill))
							.frame(width: 53, height: 53)
							.opacity(on ? 0.55 : 0.25)
					}
					.padding(.leading, 12)

					VStack(alignment: .leading, spacing: 8) {
						HStack {
							RoundedRectangle(cornerRadius: 5)
								.fill(Color(.systemFill))
								.frame(width: CGFloat([110,85,140,100,125][i%5]), height: 14)
								.opacity(on ? 0.55 : 0.25)
							Spacer()
							RoundedRectangle(cornerRadius: 5)
								.fill(Color(.systemFill))
								.frame(width: 34, height: 12)
								.opacity(on ? 0.45 : 0.2)
						}
						RoundedRectangle(cornerRadius: 5)
							.fill(Color(.systemFill))
							.frame(width: CGFloat([180,140,200,160,190][i%5]), height: 12)
							.opacity(on ? 0.38 : 0.18)
					}
					.padding(.leading, 12)
					.padding(.trailing, 16)
				}
				.padding(.vertical, 10)
				.background(Color(.secondarySystemGroupedBackground))
				.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
				.animation(.easeInOut(duration: 0.9).repeatForever().delay(Double(i)*0.08), value: on)
				.listRowBackground(Color.clear)
				.listRowSeparator(.hidden)
				.listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
			}
		}
		.listStyle(.plain)
		.scrollContentBackground(.hidden)
		.background(Color(.systemGroupedBackground))
		.onAppear { on = true }
	}
}
