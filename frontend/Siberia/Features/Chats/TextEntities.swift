// Features/Chats/TextEntities.swift
//
// Text entities — Telegram-модель форматирования:
//   пользователь печатает markdown → клиент парсит в ЧИСТЫЙ текст + массив
//   entities {type, offset, length} (offset/length — UTF-16 code units) →
//   сервер хранит и валидирует → все клиенты рендерят AttributedString.
//
// Поддержано: **bold**, *italic* / _italic_, __underline__, ~~strike~~,
// `code`, ```pre```, ||spoiler|| (tap-to-reveal).

import SwiftUI

// MARK: – Модель (соответствует schemas.message.MessageEntity на бэке)

struct MessageEntity: Codable, Equatable, Hashable {
	let type: String     // bold | italic | underline | strikethrough | code | pre | spoiler
	let offset: Int      // UTF-16 code units
	let length: Int      // UTF-16 code units
}

// MARK: – Парсер markdown → (чистый текст, entities)

enum MarkdownParser {

	/// Порядок важен: более длинные разделители раньше (``` до `, ** до *, __ до _)
	private static let patterns: [(open: String, close: String, type: String)] = [
		("```", "```", "pre"),
		("**",  "**",  "bold"),
		("__",  "__",  "underline"),
		("~~",  "~~",  "strikethrough"),
		("||",  "||",  "spoiler"),
		("`",   "`",   "code"),
		("*",   "*",   "italic"),
		("_",   "_",   "italic"),
	]

	/// Однопроходный, без вложенности (v1). Непарные разделители остаются текстом.
	static func parse(_ input: String) -> (text: String, entities: [MessageEntity]) {
		var out = ""
		var entities: [MessageEntity] = []
		var i = input.startIndex

		while i < input.endIndex {
			var matched = false
			for p in patterns {
				guard input[i...].hasPrefix(p.open) else { continue }
				let afterOpen = input.index(i, offsetBy: p.open.count)
				guard afterOpen < input.endIndex,
				      let closeRange = input.range(of: p.close, range: afterOpen..<input.endIndex)
				else { continue }
				let inner = String(input[afterOpen..<closeRange.lowerBound])
				// Пустое ("****") или начинающееся с перевода строки для inline — литерал
				guard !inner.isEmpty else { continue }

				let start = out.utf16.count
				out += inner
				entities.append(MessageEntity(type: p.type, offset: start, length: inner.utf16.count))
				i = closeRange.upperBound
				matched = true
				break
			}
			if !matched {
				out.append(input[i])
				i = input.index(after: i)
			}
		}
		return (out, entities)
	}
}

// MARK: – Рендер: текст + entities → AttributedString

enum EntityRenderer {

	/// Собирает атрибутированный текст пузыря. Сохраняет прежнюю подсветку
	/// @упоминаний, поверх — стили entities. Нераскрытый спойлер прячет
	/// символы (clear на подложке), tap-to-reveal решает вызывающий код.
	static func attributed(
		text: String,
		entities: [MessageEntity]?,
		mine: Bool,
		spoilersRevealed: Bool
	) -> AttributedString {
		// Базовый проход: подсветка @слов (прежнее поведение mentionText)
		var attr = AttributedString()
		let words = text.components(separatedBy: " ")
		for (i, word) in words.enumerated() {
			var chunk = AttributedString(i < words.count - 1 ? word + " " : word)
			if word.hasPrefix("@") {
				chunk.foregroundColor = mine ? .white : ChatDetailView.accent
				chunk.font = .body.bold()
			} else {
				chunk.foregroundColor = mine ? .white : .primary
				chunk.font = .body
			}
			attr += chunk
		}

		guard let entities, !entities.isEmpty else { return attr }

		for e in entities {
			guard let range = attributedRange(in: attr, of: text, utf16Offset: e.offset, utf16Length: e.length)
			else { continue }

			switch e.type {
			case "bold":
				attr[range].font = .body.bold()
			case "italic":
				attr[range].font = .body.italic()
			case "underline":
				attr[range].underlineStyle = .single
			case "strikethrough":
				attr[range].strikethroughStyle = .single
			case "code", "pre":
				attr[range].font = .system(.body, design: .monospaced)
				attr[range].backgroundColor = mine
					? Color.white.opacity(0.18)
					: Color(.systemFill)
			case "spoiler":
				if spoilersRevealed {
					attr[range].backgroundColor = mine
						? Color.white.opacity(0.14)
						: Color(.systemFill).opacity(0.6)
				} else {
					// Прячем содержимое: прозрачные символы на заметной подложке
					attr[range].foregroundColor = .clear
					attr[range].backgroundColor = mine
						? Color.white.opacity(0.34)
						: Color(.systemGray3)
				}
			default:
				break
			}
		}
		return attr
	}

	/// UTF-16 offset/length → Range<AttributedString.Index>.
	private static func attributedRange(
		in attr: AttributedString,
		of source: String,
		utf16Offset: Int,
		utf16Length: Int
	) -> Range<AttributedString.Index>? {
		let u16 = source.utf16
		guard
			let from16 = u16.index(u16.startIndex, offsetBy: utf16Offset, limitedBy: u16.endIndex),
			let to16 = u16.index(from16, offsetBy: utf16Length, limitedBy: u16.endIndex),
			let fromStr = String.Index(from16, within: source),
			let toStr = String.Index(to16, within: source)
		else { return nil }

		let loChars = source.distance(from: source.startIndex, to: fromStr)
		let hiChars = source.distance(from: source.startIndex, to: toStr)
		guard
			let lo = attr.index(attr.startIndex, offsetByCharacters: loChars, limitedBy: attr.endIndex),
			let hi = attr.index(attr.startIndex, offsetByCharacters: hiChars, limitedBy: attr.endIndex),
			lo <= hi
		else { return nil }
		return lo..<hi
	}
}

private extension AttributedString {
	func index(_ i: Index, offsetByCharacters n: Int, limitedBy limit: Index) -> Index? {
		var idx = i
		for _ in 0..<n {
			guard idx < limit else { return nil }
			idx = self.index(afterCharacter: idx)
		}
		return idx
	}
}
