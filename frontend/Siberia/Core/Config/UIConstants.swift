import Foundation

/// Именованные тайминги, которые раньше были разбросаны как magic numbers
/// (asyncAfter / Task.sleep) по разным View и ViewModel.
enum UIConstants {

	// MARK: – Scroll & highlight (ChatDetailView)
	/// Задержка перед scroll-to после dismiss sheet или нажатия "перейти к сообщению".
	/// Sheet анимация ~0.3s, даём небольшой запас.
	static let scrollToMessageDelay: TimeInterval = 0.35
	/// Длительность подсветки сообщения после jump-to.
	static let messageHighlightDuration: TimeInterval = 1.2

	// MARK: – Error toast
	/// Через сколько ошибка автоматически скрывается.
	static let errorToastAutoDismissSec: UInt64 = 4

	// MARK: – Realtime / presence
	/// Интервал polling presence партнёра по чату.
	static let presencePollIntervalSec: UInt64 = 30
	/// Debounce typing-индикатора (отправляем не чаще раза в N секунд).
	static let typingDebounceMs: UInt64 = 500
	/// Через сколько считаем что собеседник перестал печатать (если нет нового typing-event).
	static let typingFadeOutSec: UInt64 = 5
}

extension UInt64 {
	/// Удобный helper для `Task.sleep(nanoseconds:)`.
	var seconds_ns: UInt64 { self * 1_000_000_000 }
	var ms_ns: UInt64 { self * 1_000_000 }
}
