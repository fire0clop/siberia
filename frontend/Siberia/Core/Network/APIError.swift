import Foundation

struct APIErrorEnvelope: Codable {
	struct FieldError: Codable {
		let type: String?
		let loc: [String]?
		let msg: String?
		let input: String?
	}
	struct Err: Codable {
		let code: String?
		let message: String?
		let fields: [FieldError]?
	}

	let error: Err?
}

enum APIClientError: LocalizedError {
	case httpStatus(Int, message: String?)
	case decoding(Error)
	case noData
	case refreshFailed

	var errorDescription: String? {
		switch self {
		case .httpStatus(let code, let message):
			if let m = message, !m.isEmpty { return m }
			return "Ошибка сервера (\(code))"
		case .decoding(let e):
			return e.localizedDescription
		case .noData:
			return "Пустой ответ"
		case .refreshFailed:
			return "Сессия истекла. Войдите снова."
		}
	}
}

extension APIErrorEnvelope.FieldError {
	/// Человекочитаемое объяснение конкретного типа ошибки Pydantic.
	var humanReadable: String {
		let field = loc?.last ?? "поле"
		let label = fieldLabel(field)
		switch type {
		case "string_too_short":
			return "\(label): слишком короткое значение"
		case "string_too_long":
			return "\(label): слишком длинное значение"
		case "value_error":
			if msg?.contains("email") == true { return "Некорректный email" }
			return msg ?? "Некорректное значение"
		case "missing":
			return "\(label): не указано"
		case "string_pattern_mismatch":
			return "\(label): недопустимые символы"
		default:
			return msg ?? "\(label) — ошибка"
		}
	}

	private func fieldLabel(_ raw: String) -> String {
		switch raw {
		case "email":    return "Email"
		case "password": return "Пароль"
		case "nickname": return "Никнейм"
		case "username": return "Username"
		case "code":     return "Код"
		case "totp_code":return "Код 2FA"
		case "bio":      return "Bio"
		default:         return raw.capitalized
		}
	}
}