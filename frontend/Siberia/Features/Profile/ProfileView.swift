import PhotosUI
import SwiftUI
import UIKit

// MARK: – Aurora + star helpers (private to this file, same recipe as AuthView)

private struct ProfileAurora: View {
	let time: Double
	var body: some View {
		GeometryReader { geo in
			let w = geo.size.width
			let h = geo.size.height
			ZStack {
				Color(red: 0.04, green: 0.03, blue: 0.12).ignoresSafeArea()
				orb(x: w*(0.28+0.24*sin(time*0.130)), y: h*(0.28+0.20*cos(time*0.110)),
					r: 530, c: Color(red:0.24,green:0.30,blue:0.98))
				orb(x: w*(0.74+0.18*sin(time*0.095+1.2)), y: h*(0.54+0.24*cos(time*0.160+2.1)),
					r: 470, c: Color(red:0.52,green:0.13,blue:0.90))
				orb(x: w*(0.62+0.28*cos(time*0.205+0.9)), y: h*(0.18+0.14*sin(time*0.145+3.5)),
					r: 350, c: Color(red:0.03,green:0.70,blue:0.85))
				orb(x: w*(0.16+0.16*cos(time*0.165+4.2)), y: h*(0.74+0.18*sin(time*0.125+1.8)),
					r: 390, c: Color(red:0.72,green:0.15,blue:0.80))
			}
		}
		.blur(radius: 52)
		.ignoresSafeArea()
	}
	private func orb(x: CGFloat, y: CGFloat, r: CGFloat, c: Color) -> some View {
		RadialGradient(colors: [c.opacity(0.68), .clear], center: .center,
					   startRadius: 0, endRadius: r/2)
			.frame(width: r, height: r)
			.position(x: x, y: y)
			.blendMode(.screen)
	}
}

private struct ProfileStars: View {
	let time: Double
	private static let pts: [(Double,Double,Double,Double,Double)] = (0..<34).map {
		let a = Double($0) * 137.508
		return (sin(a)*0.5+0.5, abs(fmod(cos(a*1.618),1.0)),
				1.1+abs(fmod(sin(a*2.4),1.3)), 0.014+abs(fmod(sin(a*0.71),0.022)), a)
	}
	var body: some View {
		Canvas { ctx, size in
			for p in Self.pts {
				let y  = 1.0 - fmod(p.1 + time * p.3, 1.0)
				let x  = p.0 + 0.045 * sin(time * 0.28 + p.4)
				let op = 0.12 + 0.18 * abs(sin(time * 0.65 + p.4))
				let s  = CGFloat(p.2)
				ctx.fill(
					Path(ellipseIn: CGRect(x: x*size.width-s/2, y: y*size.height-s/2, width: s, height: s)),
					with: .color(.white.opacity(op))
				)
			}
		}
		.ignoresSafeArea()
		.allowsHitTesting(false)
	}
}

private struct GlassPressStyle: ButtonStyle {
	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.background(
				configuration.isPressed ? Color.white.opacity(0.07) : Color.clear,
				in: RoundedRectangle(cornerRadius: 14, style: .continuous)
			)
			.scaleEffect(configuration.isPressed ? 0.987 : 1)
			.animation(.easeInOut(duration: 0.10), value: configuration.isPressed)
	}
}

// MARK: – ProfileView

struct ProfileView: View {

	@EnvironmentObject private var appState: AppState

	@State private var friends:   [User]              = []
	@State private var requests:  [FriendRequestItem] = []
	@State private var sessions:  [DeviceSession]     = []
	@State private var selectedTab = 0
	@State private var isLoading   = false
	@State private var notice:     String?
	@State private var navPath     = NavigationPath()
	@State private var glowScale: CGFloat = 1.0

	// Avatar
	@State private var showAvatarActions = false
	@State private var showPhotoPicker   = false
	@State private var selectedPhoto:    PhotosPickerItem?
	@State private var isUploadingAvatar = false

	// Security
	@State private var showEmailVerify = false
	@State private var show2FASetup    = false
	@State private var show2FADisable  = false
	@State private var has2FA          = false

	// Sheets
	@State private var showPrivacy      = false
	@State private var showBlocked      = false
	@State private var showEditProfile  = false
	@State private var showSentRequests = false
	@State private var sentRequests: [FriendRequestItem] = []

	private let ac1 = Color(red: 0.44, green: 0.30, blue: 0.97)
	private let ac2 = Color(red: 0.03, green: 0.70, blue: 0.85)
	private var user: User? { appState.currentUser }

	// MARK: – Body

	var body: some View {
		NavigationStack(path: $navPath) {
			ZStack {
				// Aurora background — isolated in its own TimelineView so content views
				// don't re-render every frame
				TimelineView(.animation) { tl in
					let t = tl.date.timeIntervalSinceReferenceDate
					ZStack {
						ProfileAurora(time: t)
						ProfileStars(time: t)
					}
				}

				// Scrollable content
				ScrollView(showsIndicators: false) {
					VStack(spacing: 14) {
						profileHeader
						if !requests.isEmpty { requestsSection }
						tabPicker
						if selectedTab == 0 {
							accountSection
							settingsSection
							securitySection
							devicesSection
							logoutButton
						} else {
							friendsSection
						}
					}
					.padding(.horizontal, 16)
					.padding(.top, 4)
					.padding(.bottom, 52)
				}
				.refreshable { await reload() }
			}
			.toolbarBackground(.hidden, for: .navigationBar)
			.toolbarColorScheme(.dark, for: .navigationBar)
			.navigationBarTitleDisplayMode(.inline)
			.toolbar {
				ToolbarItem(placement: .topBarTrailing) {
					Button { showEditProfile = true } label: {
						Image(systemName: "pencil.circle.fill")
							.font(.system(size: 22))
							.foregroundStyle(.white.opacity(0.75))
							.symbolRenderingMode(.hierarchical)
					}
				}
			}
			.navigationDestination(for: ChatRoute.self) { ChatDetailView(route: $0) }
			.navigationDestination(for: User.self)      { FriendChatLoaderView(friend: $0) }
			.alert("Сообщение", isPresented: .init(
				get: { notice != nil }, set: { if !$0 { notice = nil } }
			)) {
				Button("OK", role: .cancel) { notice = nil }
			} message: { Text(notice ?? "") }
		}
		.task { await reload() }
		.onAppear {
			withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
				glowScale = 1.20
			}
		}
		.photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
		.onChange(of: selectedPhoto) { _, item in
			guard let item else { return }
			Task { await uploadAvatar(item) }
		}
		.confirmationDialog("Фото профиля", isPresented: $showAvatarActions, titleVisibility: .visible) {
			Button("Выбрать из библиотеки") { showPhotoPicker = true }
			if user?.avatarUrl != nil {
				Button("Удалить фото", role: .destructive) { Task { await removeAvatar() } }
			}
			Button("Отмена", role: .cancel) {}
		}
		.sheet(isPresented: $showEmailVerify) {
			EmailVerificationView(email: user?.email) { Task { await refreshUser() } }
		}
		.sheet(isPresented: $show2FASetup)    { TwoFactorSetupView(onCompleted: { has2FA = true }) }
		.sheet(isPresented: $show2FADisable)  { TwoFactorDisableSheet(onDisabled: { has2FA = false }) }
		.sheet(isPresented: $showPrivacy)     { PrivacySettingsView() }
		.sheet(isPresented: $showBlocked)     { BlockedListView() }
		.sheet(isPresented: $showEditProfile) { EditProfileView().environmentObject(appState) }
		.sheet(isPresented: $showSentRequests) {
			SentRequestsView(requests: $sentRequests) { Task { await loadSentRequests() } }
		}
	}

	// MARK: – Profile header (avatar + name, floating in aurora)

	private var profileHeader: some View {
		VStack(spacing: 0) {
			// Avatar
			Button { showAvatarActions = true } label: {
				ZStack {
					// Soft ambient glow — animated
					Circle()
						.fill(ac1.opacity(0.28))
						.frame(width: 140, height: 140)
						.blur(radius: 26)
						.scaleEffect(glowScale)

					// Gradient ring
					Circle()
						.fill(LinearGradient(colors: [ac1, ac2],
											 startPoint: .topLeading, endPoint: .bottomTrailing))
						.frame(width: 106, height: 106)
						.overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))

					// Dark inner frame
					Circle()
						.fill(Color(red: 0.06, green: 0.05, blue: 0.16))
						.frame(width: 98, height: 98)

					// Avatar content
					avatarContent
						.frame(width: 98, height: 98)
						.clipShape(Circle())

					// Upload overlay
					if isUploadingAvatar {
						Circle().fill(.black.opacity(0.55)).frame(width: 98, height: 98)
						ProgressView().tint(.white)
					}

					// Camera badge
					ZStack {
						Circle()
							.fill(Color(red: 0.06, green: 0.05, blue: 0.16))
							.frame(width: 30, height: 30)
							.overlay(
								Circle().stroke(
									LinearGradient(colors: [ac1, ac2],
												   startPoint: .topLeading, endPoint: .bottomTrailing),
									lineWidth: 1.5
								)
							)
						Image(systemName: "camera.fill")
							.font(.system(size: 13, weight: .semibold))
							.foregroundStyle(.white.opacity(0.85))
					}
					.offset(x: 38, y: 38)
				}
			}
			.buttonStyle(.plain)
			.padding(.top, 20)

			// Nickname
			Text(user?.nickname ?? " ")
				.font(.system(size: 26, weight: .bold, design: .rounded))
				.foregroundStyle(.white)
				.padding(.top, 16)

			// Bio
			if let bio = user?.bio, !bio.isEmpty {
				Text(bio)
					.font(.system(size: 14))
					.foregroundStyle(.white.opacity(0.42))
					.multilineTextAlignment(.center)
					.padding(.horizontal, 40)
					.padding(.top, 5)
			}

			// Email
			if let email = user?.email {
				Text(email)
					.font(.system(size: 13))
					.foregroundStyle(.white.opacity(0.28))
					.padding(.top, 4)
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.bottom, 28)
	}

	@ViewBuilder
	private var avatarContent: some View {
		if let str = user?.avatarUrl, let url = URL(string: str) {
			AsyncImage(url: url) { phase in
				if case .success(let img) = phase {
					img.resizable().scaledToFill()
				} else {
					initialsCircle
				}
			}
		} else {
			initialsCircle
		}
	}

	private var initialsCircle: some View {
		ZStack {
			Color.clear
			Text(String((user?.nickname ?? "?").prefix(1)).uppercased())
				.font(.system(size: 34, weight: .bold))
				.foregroundStyle(.white)
		}
	}

	// MARK: – Tab picker

	private var tabPicker: some View {
		HStack(spacing: 0) {
			tabPill(title: "Профиль", index: 0)
			tabPill(
				title: friends.isEmpty ? "Друзья" : "Друзья (\(friends.count))",
				index: 1
			)
		}
		.background(.white.opacity(0.05))
		.overlay(
			RoundedRectangle(cornerRadius: 14, style: .continuous)
				.stroke(.white.opacity(0.10), lineWidth: 1)
		)
		.clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
	}

	private func tabPill(title: String, index: Int) -> some View {
		Button {
			withAnimation(.spring(response: 0.30, dampingFraction: 0.75)) { selectedTab = index }
		} label: {
			Text(title)
				.font(.system(size: 14, weight: selectedTab == index ? .semibold : .regular))
				.foregroundStyle(selectedTab == index ? .white : .white.opacity(0.38))
				.frame(maxWidth: .infinity)
				.padding(.vertical, 10)
				.background(
					Group {
						if selectedTab == index {
							RoundedRectangle(cornerRadius: 11, style: .continuous)
								.fill(LinearGradient(colors: [ac1, ac2],
													 startPoint: .leading, endPoint: .trailing))
						} else {
							Color.clear
						}
					}
				)
				.padding(3)
		}
		.buttonStyle(.plain)
	}

	// MARK: – Friend requests

	private var requestsSection: some View {
		glassCard(title: "Входящие заявки") {
			ForEach(Array(requests.enumerated()), id: \.element.id) { idx, r in
				if idx > 0 { glassDivider }
				HStack(spacing: 14) {
					miniAvatar(r.user.nickname, seed: r.user.id)
					VStack(alignment: .leading, spacing: 2) {
						Text(r.user.nickname)
							.font(.system(size: 15, weight: .semibold))
							.foregroundStyle(.white)
						if let e = r.user.email {
							Text(e).font(.system(size: 12)).foregroundStyle(.white.opacity(0.32))
						}
					}
					Spacer()
					HStack(spacing: 10) {
						iconCircleButton(icon: "xmark", color: Color(red:0.90,green:0.25,blue:0.35)) {
							Task { await reject(r) }
						}
						iconCircleButton(icon: "checkmark", color: .green) {
							Task { await accept(r) }
						}
					}
				}
				.padding(.horizontal, 16).padding(.vertical, 12)
			}
		}
	}

	// MARK: – Account

	private var accountSection: some View {
		glassCard(title: "Аккаунт") {
			if let u = user {
				glassInfoRow(icon: "at", color: ac1, label: "Никнейм", value: u.nickname)
				if let e = u.email {
					glassDivider
					glassInfoRow(icon: "envelope.fill", color: ac2, label: "Email", value: e)
				}
			} else {
				HStack { ProgressView().tint(.white); Spacer() }.padding(16)
			}
		}
	}

	// MARK: – Settings

	private var settingsSection: some View {
		glassCard(title: "Настройки") {
			glassNavRow(icon: "lock.fill",
						color: Color(red:0.44,green:0.30,blue:0.97),
						title: "Конфиденциальность") { showPrivacy = true }
			glassDivider
			glassNavRow(icon: "person.crop.circle.badge.xmark",
						color: Color(red:0.90,green:0.25,blue:0.35),
						title: "Заблокированные") { showBlocked = true }
			glassDivider
			glassNavRow(icon: "paperplane.fill",
						color: Color(red:0.95,green:0.55,blue:0.15),
						title: "Исходящие заявки\(sentRequests.isEmpty ? "" : " (\(sentRequests.count))")") {
				showSentRequests = true
			}
		}
	}

	// MARK: – Security

	private var securitySection: some View {
		glassCard(title: "Безопасность") {
			HStack(spacing: 14) {
				glassIconBadge(
					icon: (user?.emailVerified ?? false) ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
					color: (user?.emailVerified ?? false) ? .green : Color(red:0.95,green:0.65,blue:0.10)
				)
				VStack(alignment: .leading, spacing: 3) {
					Text("Email")
						.font(.system(size: 15, weight: .medium))
						.foregroundStyle(.white)
					Text((user?.emailVerified ?? false) ? "Подтверждён" : "Не подтверждён")
						.font(.system(size: 12)).foregroundStyle(.white.opacity(0.38))
				}
				Spacer()
				if !(user?.emailVerified ?? false) {
					Button("Подтвердить") { showEmailVerify = true }
						.font(.system(size: 13, weight: .semibold))
						.foregroundStyle(ac2)
				}
			}
			.padding(.horizontal, 16).padding(.vertical, 13)

			glassDivider

			HStack(spacing: 14) {
				glassIconBadge(
					icon: has2FA ? "lock.shield.fill" : "lock.shield",
					color: has2FA ? .green : Color(.systemGray2)
				)
				VStack(alignment: .leading, spacing: 3) {
					Text("Двухфакторная защита")
						.font(.system(size: 15, weight: .medium))
						.foregroundStyle(.white)
					Text(has2FA ? "Включена" : "Выключена")
						.font(.system(size: 12)).foregroundStyle(.white.opacity(0.38))
				}
				Spacer()
				Button(has2FA ? "Выключить" : "Включить") {
					if has2FA { show2FADisable = true } else { show2FASetup = true }
				}
				.font(.system(size: 13, weight: .semibold))
				.foregroundStyle(has2FA ? Color(red:0.90,green:0.25,blue:0.35) : ac1)
			}
			.padding(.horizontal, 16).padding(.vertical, 13)
		}
	}

	// MARK: – Devices

	@ViewBuilder
	private var devicesSection: some View {
		glassCard(title: "Активные устройства") {
			Button { Task { await revokeAllOthers() } } label: {
				HStack(spacing: 14) {
					glassIconBadge(icon: "rectangle.stack.badge.minus",
								   color: Color(red:0.95,green:0.55,blue:0.15))
					Text("Завершить все другие сессии")
						.font(.system(size: 15))
						.foregroundStyle(Color(red:0.95,green:0.55,blue:0.15))
					Spacer()
				}
				.padding(.horizontal, 16).padding(.vertical, 13)
				.contentShape(Rectangle())
			}
			.buttonStyle(GlassPressStyle())

			if !sessions.isEmpty {
				glassDivider
				ForEach(Array(sessions.enumerated()), id: \.element.id) { idx, s in
					if idx > 0 { glassDivider }
					deviceRow(s)
				}
			}
		}
	}

	private func deviceRow(_ s: DeviceSession) -> some View {
		let isCurrent = s.deviceId == DeviceIDStorage.shared.deviceId
		let name = resolvedDeviceName(s)
		let icon = resolvedDeviceIcon(s)

		return HStack(spacing: 14) {
			ZStack {
				RoundedRectangle(cornerRadius: 12, style: .continuous)
					.fill(isCurrent ? ac1.opacity(0.20) : Color.white.opacity(0.07))
					.frame(width: 50, height: 50)
				Image(systemName: icon)
					.font(.system(size: 24, weight: .light))
					.foregroundStyle(isCurrent ? ac1 : .white.opacity(0.55))
			}

			VStack(alignment: .leading, spacing: 5) {
				HStack(spacing: 8) {
					Text(name)
						.font(.system(size: 15, weight: .semibold))
						.foregroundStyle(.white)
					if isCurrent {
						Text("Текущее")
							.font(.system(size: 10, weight: .bold))
							.foregroundStyle(.white)
							.padding(.horizontal, 8).padding(.vertical, 3)
							.background(
								LinearGradient(colors: [ac1, ac2],
											   startPoint: .leading, endPoint: .trailing),
								in: Capsule()
							)
					}
				}
				Text(relativeTime(s.lastActive))
					.font(.system(size: 12))
					.foregroundStyle(.white.opacity(0.32))
			}

			Spacer()

			if !isCurrent {
				Button { Task { await revokeOne(s) } } label: {
					Image(systemName: "xmark.circle.fill")
						.font(.system(size: 22))
						.foregroundStyle(.white.opacity(0.22))
						.symbolRenderingMode(.hierarchical)
				}
				.buttonStyle(.plain)
			}
		}
		.padding(.horizontal, 16).padding(.vertical, 13)
	}

	// MARK: – Logout

	private var logoutButton: some View {
		Button { Task { await appState.logout() } } label: {
			HStack {
				Spacer()
				Label("Выйти из аккаунта", systemImage: "rectangle.portrait.and.arrow.right")
					.font(.system(size: 16, weight: .semibold))
					.foregroundStyle(Color(red:0.90,green:0.25,blue:0.35))
				Spacer()
			}
			.padding(.vertical, 16)
			.background(.white.opacity(0.05))
			.overlay(
				RoundedRectangle(cornerRadius: 16, style: .continuous)
					.stroke(Color(red:0.90,green:0.25,blue:0.35).opacity(0.28), lineWidth: 1)
			)
			.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
		}
		.buttonStyle(GlassPressStyle())
	}

	// MARK: – Friends

	@ViewBuilder
	private var friendsSection: some View {
		if isLoading && friends.isEmpty {
			ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.vertical, 56)
		} else if friends.isEmpty {
			VStack(spacing: 14) {
				Image(systemName: "person.2.slash")
					.font(.system(size: 44))
					.foregroundStyle(.white.opacity(0.18))
				Text("Нет друзей")
					.font(.subheadline)
					.foregroundStyle(.white.opacity(0.28))
			}
			.frame(maxWidth: .infinity).padding(.vertical, 60)
		} else {
			glassCard(title: "Друзья") {
				ForEach(Array(friends.enumerated()), id: \.element.id) { idx, friend in
					if idx > 0 { glassDivider }
					Button { navPath.append(friend) } label: {
						HStack(spacing: 14) {
							friendAvatar(friend)
							VStack(alignment: .leading, spacing: 2) {
								Text(friend.nickname)
									.font(.system(size: 15, weight: .semibold))
									.foregroundStyle(.white)
								if let e = friend.email {
									Text(e).font(.system(size: 12)).foregroundStyle(.white.opacity(0.32))
								}
							}
							Spacer()
							Image(systemName: "message.fill")
								.font(.system(size: 14))
								.foregroundStyle(ac1.opacity(0.65))
						}
						.padding(.horizontal, 16).padding(.vertical, 12)
					}
					.buttonStyle(GlassPressStyle())
					.contextMenu {
						Button(role: .destructive) { Task { await removeFriend(friend) } } label: {
							Label("Удалить из друзей", systemImage: "person.crop.circle.badge.xmark")
						}
						Button(role: .destructive) { Task { await blockUser(friend) } } label: {
							Label("Заблокировать", systemImage: "hand.raised.fill")
						}
					}
				}
			}
		}
	}

	// MARK: – Reusable glass components

	private func glassCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
		VStack(alignment: .leading, spacing: 8) {
			Text(title.uppercased())
				.font(.system(size: 11, weight: .semibold))
				.foregroundStyle(.white.opacity(0.32))
				.padding(.horizontal, 4)
			VStack(spacing: 0) { content() }
				.background(.white.opacity(0.05))
				.overlay(
					RoundedRectangle(cornerRadius: 16, style: .continuous)
						.stroke(.white.opacity(0.10), lineWidth: 1)
				)
				.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
		}
	}

	private var glassDivider: some View {
		Rectangle()
			.fill(.white.opacity(0.07))
			.frame(height: 0.5)
			.padding(.leading, 62)
	}

	private func glassNavRow(icon: String, color: Color, title: String, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			HStack(spacing: 14) {
				glassIconBadge(icon: icon, color: color)
				Text(title).font(.system(size: 15)).foregroundStyle(.white)
				Spacer()
				Image(systemName: "chevron.right")
					.font(.system(size: 12, weight: .bold))
					.foregroundStyle(.white.opacity(0.18))
			}
			.padding(.horizontal, 16).padding(.vertical, 13)
			.contentShape(Rectangle())
		}
		.buttonStyle(GlassPressStyle())
	}

	private func glassInfoRow(icon: String, color: Color, label: String, value: String) -> some View {
		HStack(spacing: 14) {
			glassIconBadge(icon: icon, color: color)
			Text(label).font(.system(size: 15)).foregroundStyle(.white.opacity(0.45))
			Spacer()
			Text(value).font(.system(size: 15)).foregroundStyle(.white).lineLimit(1)
		}
		.padding(.horizontal, 16).padding(.vertical, 13)
	}

	private func glassIconBadge(icon: String, color: Color) -> some View {
		ZStack {
			RoundedRectangle(cornerRadius: 8, style: .continuous)
				.fill(color.opacity(0.18))
				.frame(width: 32, height: 32)
			Image(systemName: icon)
				.font(.system(size: 14, weight: .semibold))
				.foregroundStyle(color)
		}
	}

	private func iconCircleButton(icon: String, color: Color, action: @escaping () -> Void) -> some View {
		Button(action: action) {
			ZStack {
				Circle().fill(color.opacity(0.16)).frame(width: 36, height: 36)
				Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(color)
			}
		}.buttonStyle(.plain)
	}

	// MARK: – Avatar helpers

	private func friendAvatar(_ u: User) -> some View {
		let c = seedColor(u.id)
		return ZStack {
			Circle().fill(c.gradient)
			if let str = u.avatarUrl, let url = URL(string: str) {
				AsyncImage(url: url) { phase in
					if case .success(let img) = phase {
						img.resizable().scaledToFill().clipShape(Circle())
					} else { initialsLabel(u.nickname) }
				}
			} else { initialsLabel(u.nickname) }
		}
		.frame(width: 44, height: 44)
	}

	private func miniAvatar(_ name: String, seed: Int) -> some View {
		ZStack {
			Circle().fill(seedColor(seed).gradient)
			initialsLabel(name)
		}.frame(width: 44, height: 44)
	}

	private func initialsLabel(_ name: String) -> some View {
		Text(String(name.prefix(1)).uppercased())
			.font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
	}

	private func seedColor(_ seed: Int) -> Color {
		let p: [Color] = [.blue, .purple, .orange, .pink, .green, .teal, .indigo, .cyan]
		return p[abs(seed) % p.count]
	}

	// MARK: – Device name / icon resolution

	private func resolvedDeviceName(_ s: DeviceSession) -> String {
		// Current device → always accurate, no parsing needed
		if s.deviceId == DeviceIDStorage.shared.deviceId {
			return UIDevice.current.name
		}
		let ua = s.userAgent ?? ""
		// New format: "Siberia/1.0 (DeviceName; iPhone; iOS x.x)"
		if ua.hasPrefix("Siberia/"),
		   let inner = ua.firstMatch(of: /\(([^)]+)\)/)?.output.1 {
			let name = String(inner.split(separator: ";").first ?? "").trimmingCharacters(in: .whitespaces)
			if !name.isEmpty { return name }
		}
		// Generic fallbacks
		if ua.contains("iPhone")               { return "iPhone" }
		if ua.contains("iPad")                 { return "iPad" }
		if ua.contains("Macintosh") || ua.contains("Mac OS X") { return "Mac" }
		if ua.contains("Windows")              { return "Windows" }
		// CFNetwork default UA → still an iOS device (app is iOS-only)
		return "iPhone"
	}

	private func resolvedDeviceIcon(_ s: DeviceSession) -> String {
		if s.deviceId == DeviceIDStorage.shared.deviceId {
			return UIDevice.current.model.lowercased().contains("ipad") ? "ipad" : "iphone"
		}
		let ua = s.userAgent ?? ""
		if ua.hasPrefix("Siberia/"),
		   let inner = ua.firstMatch(of: /\(([^)]+)\)/)?.output.1 {
			let model = String(inner.split(separator: ";").dropFirst().first ?? "").trimmingCharacters(in: .whitespaces)
			if model.contains("iPad")    { return "ipad" }
			if model.contains("iPhone")  { return "iphone" }
			if model.contains("Mac")     { return "laptopcomputer" }
		}
		if ua.contains("iPad")    { return "ipad" }
		if ua.contains("iPhone")  { return "iphone" }
		if ua.contains("Macintosh") || ua.contains("Mac OS X") { return "laptopcomputer" }
		return "iphone"
	}

	// MARK: – Relative time

	private func relativeTime(_ iso: String) -> String {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		var d = f.date(from: iso)
		if d == nil { f.formatOptions = [.withInternetDateTime]; d = f.date(from: iso) }
		guard let date = d else { return "—" }
		let diff = Date().timeIntervalSince(date)
		switch diff {
		case ..<60:     return "только что"
		case ..<3600:   return "\(Int(diff/60)) мин назад"
		case ..<86400:  return "\(Int(diff/3600)) ч назад"
		case ..<604800: return "\(Int(diff/86400)) д назад"
		default:        return "\(Int(diff/604800)) нед назад"
		}
	}

	// MARK: – Data loading

	private func reload() async {
		isLoading = true; defer { isLoading = false }
		async let u: () = refreshUser()
		async let r: () = loadRequests()
		async let s: () = loadSessions()
		async let f: () = loadFriends()
		async let so: () = loadSentRequests()
		_ = await (u, r, s, f, so)
	}

	private func refreshUser()      async { do { appState.currentUser = try await UserService.shared.me() } catch {} }
	private func loadRequests()     async { do { requests = try await FriendService.shared.getRequests() } catch {} }
	private func loadSessions()     async { do { sessions = try await SessionService.shared.listSessions() } catch {} }
	private func loadFriends()      async { do { friends  = try await FriendService.shared.getFriends() } catch {} }
	private func loadSentRequests() async {
		if let l = try? await FriendService.shared.getSentRequests() { sentRequests = l }
	}

	private func accept(_ r: FriendRequestItem) async {
		do { try await FriendService.shared.accept(requestId: r.requestId); notice = "Заявка принята"; await reload() }
		catch { notice = error.localizedDescription }
	}
	private func reject(_ r: FriendRequestItem) async {
		do { try await FriendService.shared.reject(requestId: r.requestId); requests.removeAll { $0.requestId == r.requestId } }
		catch { notice = error.localizedDescription }
	}
	private func removeFriend(_ f: User) async {
		do { try await FriendService.shared.remove(userId: f.id); friends.removeAll { $0.id == f.id }; notice = "Друг удалён" }
		catch { notice = error.localizedDescription }
	}
	private func blockUser(_ u: User) async {
		do { try await UserService.shared.block(userId: u.id); friends.removeAll { $0.id == u.id }; notice = "Заблокирован" }
		catch { notice = error.localizedDescription }
	}
	private func revokeOne(_ s: DeviceSession) async {
		do { try await SessionService.shared.revokeSession(id: s.id); await loadSessions() }
		catch { notice = error.localizedDescription }
	}
	private func revokeAllOthers() async {
		do { try await SessionService.shared.revokeAllOtherSessions(); notice = "Сессии завершены"; await loadSessions() }
		catch { notice = error.localizedDescription }
	}

	private func uploadAvatar(_ item: PhotosPickerItem) async {
		guard let data = try? await item.loadTransferable(type: Data.self),
			  let ui = UIImage(data: data),
			  let jpeg = ui.jpegData(compressionQuality: 0.85) else { return }
		isUploadingAvatar = true; defer { isUploadingAvatar = false; selectedPhoto = nil }
		do {
			let up = try await MediaService.shared.upload(
				data: jpeg, fileName: "avatar.jpg", mimeType: "image/jpeg", type: "image"
			)
			appState.currentUser = try await UserService.shared.setAvatar(mediaId: up.id)
		} catch { notice = "Ошибка загрузки: \(error.localizedDescription)" }
	}

	private func removeAvatar() async {
		isUploadingAvatar = true; defer { isUploadingAvatar = false }
		do { appState.currentUser = try await UserService.shared.deleteAvatar() }
		catch { notice = "Не удалось удалить аватар" }
	}
}

// MARK: – Friend chat loader

struct FriendChatLoaderView: View {
	let friend: User
	@State private var route: ChatRoute?
	@State private var error: String?

	var body: some View {
		Group {
			if let route { ChatDetailView(route: route) }
			else if let error {
				ContentUnavailableView(
					"Не удалось открыть чат",
					systemImage: "exclamationmark.triangle",
					description: Text(error)
				)
			} else {
				ProgressView("Открываем чат…").task { await open() }
			}
		}
	}

	private func open() async {
		do {
			let chat = try await ChatService.shared.createChat(withUserId: friend.id)
			route = ChatRoute(chatId: chat.id, title: friend.nickname, syncSeq: chat.syncSeq)
		} catch { self.error = error.localizedDescription }
	}
}
