import SwiftUI

/// Информация о групповом чате: участники, роли, добавить/удалить, выйти.
struct GroupInfoSheet: View {

	@ObservedObject var vm: ChatDetailViewModel
	@Environment(\.dismiss) private var dismiss

	@State private var showAddMembers = false
	@State private var memberToActionOn: ChatMember? = nil
	@State private var confirmLeave = false
	@State private var notice: String?
	@State private var error: String?
	@State private var isBusy = false
	@State private var isMuted = false
	@State private var showMuteSheet = false

	private var myRole: String? {
		vm.chatMembers.first(where: { $0.userId == vm.currentUserId })?.role
	}
	private var isAdmin: Bool { myRole == "admin" || myRole == "owner" }
	private var isOwner: Bool { myRole == "owner" }

	var body: some View {
		NavigationStack {
			List {
				Section {
					HStack {
						Spacer()
						VStack(spacing: 10) {
							ZStack {
								Circle().fill(LinearGradient(
									colors: [Color.indigo, Color.purple],
									startPoint: .topLeading, endPoint: .bottomTrailing
								))
								.frame(width: 86, height: 86)
								Text(String(vm.title.prefix(1)).uppercased())
									.font(.system(size: 36, weight: .bold))
									.foregroundStyle(.white)
							}
							Text(vm.title).font(.title3.bold())
							Text("\(vm.chatMembers.count) участников")
								.font(.caption)
								.foregroundStyle(.secondary)
						}
						.padding(.vertical, 10)
						Spacer()
					}
					.listRowBackground(Color.clear)
				}

				Section {
					Button {
						if isMuted { Task { await unmute() } }
						else { showMuteSheet = true }
					} label: {
						Label(isMuted ? "Включить уведомления" : "Отключить уведомления",
							  systemImage: isMuted ? "bell.fill" : "bell.slash.fill")
							.foregroundStyle(isMuted ? Color.accentColor : .orange)
					}
				}

				Section("Участники") {
					if isAdmin {
						Button {
							showAddMembers = true
						} label: {
							Label("Добавить участников", systemImage: "person.badge.plus")
						}
					}
					ForEach(vm.chatMembers) { member in
						memberRow(member)
							.contentShape(Rectangle())
							.onTapGesture {
								// Можно действовать только по другим членам и если я admin/owner
								if isAdmin && member.userId != vm.currentUserId {
									memberToActionOn = member
								}
							}
					}
				}

				Section {
					Button(role: .destructive) {
						confirmLeave = true
					} label: {
						Label(isOwner ? "Покинуть группу (передаст права)" : "Покинуть группу",
							  systemImage: "rectangle.portrait.and.arrow.right")
					}
				}
			}
			.navigationTitle("Информация")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button("Готово") { dismiss() }
				}
			}
			.confirmationDialog(
				"Действие с участником",
				isPresented: .init(get: { memberToActionOn != nil }, set: { if !$0 { memberToActionOn = nil } }),
				titleVisibility: .visible,
				presenting: memberToActionOn
			) { member in
				if isOwner {
					if member.role != "admin" {
						Button("Сделать админом") { Task { await changeRole(member, to: "admin") } }
					} else {
						Button("Снять с админа") { Task { await changeRole(member, to: "member") } }
					}
				}
				Button("Удалить из группы", role: .destructive) {
					Task { await kick(member) }
				}
				Button("Отмена", role: .cancel) {}
			} message: { member in
				Text(member.user.nickname)
			}
			.confirmationDialog("Отключить уведомления", isPresented: $showMuteSheet, titleVisibility: .visible) {
				Button("На 1 час")   { Task { await muteFor(hours: 1) } }
				Button("На 8 часов") { Task { await muteFor(hours: 8) } }
				Button("Навсегда")   { Task { await muteFor(hours: nil) } }
				Button("Отмена", role: .cancel) {}
			}
			.alert("Покинуть группу?", isPresented: $confirmLeave) {
				Button("Покинуть", role: .destructive) { Task { await leave() } }
				Button("Отмена", role: .cancel) {}
			}
			.alert("Сообщение", isPresented: .init(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
				Button("OK", role: .cancel) { notice = nil }
			} message: { Text(notice ?? "") }
			.alert("Ошибка", isPresented: .init(get: { error != nil }, set: { if !$0 { error = nil } })) {
				Button("OK", role: .cancel) { error = nil }
			} message: { Text(error ?? "") }
			.sheet(isPresented: $showAddMembers) {
				AddGroupMembersSheet(currentMemberIds: Set(vm.chatMembers.map(\.userId))) { added in
					Task { await addMembers(added) }
				}
			}
			.overlay {
				if isBusy {
					Color.black.opacity(0.15).ignoresSafeArea()
					ProgressView().controlSize(.large).tint(.white)
				}
			}
		}
	}

	private func memberRow(_ m: ChatMember) -> some View {
		HStack(spacing: 12) {
			ZStack {
				let palette: [Color] = [.blue, .purple, .orange, .pink, .green, .teal, .indigo, .cyan]
				let color = palette[abs(m.userId) % palette.count]
				Circle().fill(color.gradient).frame(width: 36, height: 36)
				if let s = m.user.avatarUrl, let url = URL(string: s) {
					AsyncImage(url: url) { phase in
						if case .success(let img) = phase {
							img.resizable().scaledToFill().clipShape(Circle())
						} else {
							Text(String(m.user.nickname.prefix(1)).uppercased())
								.font(.system(size: 14, weight: .semibold))
								.foregroundStyle(.white)
						}
					}
					.frame(width: 36, height: 36)
				} else {
					Text(String(m.user.nickname.prefix(1)).uppercased())
						.font(.system(size: 14, weight: .semibold))
						.foregroundStyle(.white)
				}
			}
			VStack(alignment: .leading, spacing: 2) {
				Text(m.user.nickname).font(.system(size: 15, weight: .medium))
				if let e = m.user.email {
					Text(e).font(.caption).foregroundStyle(.secondary).lineLimit(1)
				}
			}
			Spacer()
			if m.role == "owner" {
				roleBadge("владелец", color: .orange)
			} else if m.role == "admin" {
				roleBadge("админ", color: .blue)
			}
		}
	}

	private func roleBadge(_ text: String, color: Color) -> some View {
		Text(text.uppercased())
			.font(.system(size: 10, weight: .bold))
			.foregroundStyle(color)
			.padding(.horizontal, 8).padding(.vertical, 3)
			.background(color.opacity(0.15))
			.clipShape(Capsule())
	}

	// MARK: – Actions

	@MainActor private func addMembers(_ ids: [Int]) async {
		guard !ids.isEmpty else { return }
		isBusy = true; defer { isBusy = false }
		do {
			try await ChatService.shared.addMembers(chatId: vm.chatId, userIds: ids)
			await reloadMembers()
			notice = "Участники добавлены"
		} catch {
			Log.chat.error("addMembers failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor private func kick(_ m: ChatMember) async {
		isBusy = true; defer { isBusy = false }
		do {
			try await ChatService.shared.removeMember(chatId: vm.chatId, userId: m.userId)
			await reloadMembers()
		} catch {
			Log.chat.error("removeMember failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor private func changeRole(_ m: ChatMember, to role: String) async {
		isBusy = true; defer { isBusy = false }
		do {
			try await ChatService.shared.changeMemberRole(chatId: vm.chatId, userId: m.userId, role: role)
			await reloadMembers()
		} catch {
			Log.chat.error("changeRole failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor private func leave() async {
		isBusy = true; defer { isBusy = false }
		do {
			try await ChatService.shared.leaveChat(chatId: vm.chatId)
			dismiss()
			// Notify chats list to refresh
			NotificationCenter.default.post(name: .siberiaChatsShouldReload, object: nil)
		} catch {
			Log.chat.error("leaveChat failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor private func reloadMembers() async {
		if let members = try? await ChatService.shared.members(chatId: vm.chatId) {
			vm.chatMembers = members
		}
	}

	@MainActor private func muteFor(hours: Int?) async {
		do {
			let until: Date? = hours.map { Date().addingTimeInterval(TimeInterval($0 * 3600)) }
			try await ChatService.shared.mute(chatId: vm.chatId, until: until)
			isMuted = true
		} catch {
			Log.chat.error("mute failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}

	@MainActor private func unmute() async {
		do {
			try await ChatService.shared.unmute(chatId: vm.chatId)
			isMuted = false
		} catch {
			Log.chat.error("unmute failed: \(String(describing: error))")
			self.error = error.localizedDescription
		}
	}
}

/// Лист добавления участников в существующую группу.
private struct AddGroupMembersSheet: View {
	let currentMemberIds: Set<Int>
	let onAdd: ([Int]) -> Void

	@Environment(\.dismiss) private var dismiss
	@State private var friends: [User] = []
	@State private var selectedIds = Set<Int>()
	@State private var searchText = ""

	private var filtered: [User] {
		let pool = friends.filter { !currentMemberIds.contains($0.id) }
		guard !searchText.isEmpty else { return pool }
		let q = searchText.lowercased()
		return pool.filter { $0.nickname.lowercased().contains(q) }
	}

	var body: some View {
		NavigationStack {
			Form {
				Section {
					TextField("Поиск", text: $searchText)
						.textInputAutocapitalization(.never)
						.autocorrectionDisabled()
				}
				Section("Друзья (\(selectedIds.count) выбрано)") {
					if friends.isEmpty {
						HStack { Spacer(); ProgressView(); Spacer() }
					} else if filtered.isEmpty {
						Text("Нет доступных друзей").foregroundStyle(.secondary)
					}
					ForEach(filtered) { f in
						Button {
							if selectedIds.contains(f.id) { selectedIds.remove(f.id) } else { selectedIds.insert(f.id) }
						} label: {
							HStack {
								Text(f.nickname).foregroundStyle(.primary)
								Spacer()
								Image(systemName: selectedIds.contains(f.id) ? "checkmark.circle.fill" : "circle")
									.foregroundStyle(selectedIds.contains(f.id) ? Color.accentColor : .secondary)
							}
						}
						.buttonStyle(.plain)
					}
				}
			}
			.navigationTitle("Добавить участников")
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					Button("Отмена") { dismiss() }
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button("Добавить") {
						onAdd(Array(selectedIds))
						dismiss()
					}
					.fontWeight(.semibold)
					.disabled(selectedIds.isEmpty)
				}
			}
		}
		.task {
			friends = (try? await FriendService.shared.getFriends()) ?? []
		}
	}
}
