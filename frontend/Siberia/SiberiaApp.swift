import SwiftUI
import UserNotifications

@main
struct SiberiaApp: App {

	@UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
	@StateObject private var appState = AppState()

	init() {
		UNUserNotificationCenter.current().delegate = SiberiaNotificationDelegate.shared
		// Large URLCache so presigned image URLs are cached on disk (up to 500 MB)
		URLCache.shared = URLCache(
			memoryCapacity: 50 * 1_024 * 1_024,
			diskCapacity: 500 * 1_024 * 1_024
		)
	}

	var body: some Scene {
		WindowGroup {
			if appState.isAuthenticated {
				MainView()
					.environmentObject(appState)
			} else {
				AuthView()
					.environmentObject(appState)
			}
		}
	}
}

// MARK: – AppDelegate (APNs + PushKit + CallKit)

final class AppDelegate: NSObject, UIApplicationDelegate {

	func application(
		_ application: UIApplication,
		didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
	) -> Bool {
		// CallKit-провайдер должен быть инициализирован ДО первого VoIP-пуша
		_ = CallKitManager.shared
		// PushKit-реестр должен подняться сразу, иначе ранние пуши потеряются
		VoIPPushManager.shared.start()
		return true
	}

	// MARK: – Standard APNs (для алёртов о сообщениях)

	func application(
		_ application: UIApplication,
		didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
	) {
		let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
		Log.push.info("APNs token received (length=\(tokenString.count))")
		Task {
			do {
				try await PushTokenService.shared.register(token: tokenString, kind: .apns)
				Log.push.info("APNs token registered on backend")
			} catch {
				Log.push.error("Failed to register APNs token: \(String(describing: error))")
			}
		}
	}

	func application(
		_ application: UIApplication,
		didFailToRegisterForRemoteNotificationsWithError error: Error
	) {
		Log.push.error("APNs registration failed: \(error.localizedDescription)")
	}
}
