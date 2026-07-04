import Foundation
import os

/// Лёгкая обёртка над `os.Logger`.
///
/// Использовать вместо `print` и `try?` без логов:
///     Log.network.error("Refresh failed: \(error)")
///
/// Категории отделены чтобы можно было фильтровать в Console.app по subsystem "app.siberia".
// nonisolated: os.Logger потокобезопасен, логировать можно из любого потока
// (WebRTC-делегаты, URLSession-колбэки), без прыжка на MainActor.
nonisolated struct LogCategory {
	let category: String
	private let logger: Logger

	fileprivate init(_ category: String) {
		self.category = category
		self.logger = Logger(subsystem: "app.siberia", category: category)
	}

	func info(_ message: String) {
		logger.info("\(message, privacy: .public)")
	}

	func warning(_ message: String) {
		logger.warning("\(message, privacy: .public)")
	}

	func error(_ message: String) {
		logger.error("\(message, privacy: .public)")
	}

	func debug(_ message: String) {
		logger.debug("\(message, privacy: .public)")
	}
}

nonisolated enum Log {
	static let auth     = LogCategory("auth")
	static let network  = LogCategory("network")
	static let realtime = LogCategory("realtime")
	static let chat     = LogCategory("chat")
	static let profile  = LogCategory("profile")
	static let push     = LogCategory("push")
	static let media    = LogCategory("media")
	static let cache    = LogCategory("cache")
	static let calls    = LogCategory("calls")
}
