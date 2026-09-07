import SwiftUI

struct MainView: View {

	@EnvironmentObject var appState: AppState
	@State private var selectedTab = 0

	init() {
		// Custom tab bar appearance — blurred material, no top line
		let img = UIImage()
		let a = UITabBarAppearance()
		a.configureWithTransparentBackground()
		a.shadowImage = img
		a.backgroundImage = img
		a.backgroundEffect = UIBlurEffect(style: .systemMaterial)
		UITabBar.appearance().standardAppearance   = a
		UITabBar.appearance().scrollEdgeAppearance = a
		UITabBar.appearance().unselectedItemTintColor = UIColor.secondaryLabel
	}

	var body: some View {
		TabView(selection: $selectedTab) {
			ChatsView()
				.tabItem { Label("Чаты",   systemImage: "message") }
				.tag(0)

			AddFriendView()
				.tabItem { Label("Люди",   systemImage: "person.2") }
				.tag(1)

			ProfileView()
				.tabItem { Label("Профиль", systemImage: "person.crop.circle") }
				.tag(2)
		}
		.tint(Color.accentColor)
		// Тап по пушу должен показать чат, даже если открыта другая вкладка
		.onReceive(NotificationCenter.default.publisher(for: .siberiaOpenChat)) { _ in
			selectedTab = 0
		}
		// Входящий звонок теперь показывает САМ iOS через CallKit (системный
		// экран с зелёной/красной кнопкой). Нашу IncomingCallView больше не
		// открываем — CallKit передаст результат через CXProvider-делегат.
		// ── Активный звонок (исходящий или принятый) ───────────────────────
		.fullScreenCover(isPresented: .init(
			get: { appState.activeCall != nil },
			set: { _ in }
		)) {
			if let active = appState.activeCall, let manager = appState.callManager {
				ActiveCallView(
					call: active,
					manager: manager,
					onEnd: { Task { await appState.endActiveCall() } }
				)
			}
		}
		// ── Ошибка звонка (диагностика) ─────────────────────────────────────
		.alert("Ошибка звонка", isPresented: .init(
			get: { appState.callError != nil },
			set: { if !$0 { appState.callError = nil } }
		)) {
			Button("OK", role: .cancel) { appState.callError = nil }
		} message: {
			Text(appState.callError ?? "")
		}
	}
}
