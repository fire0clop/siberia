import Foundation
import UIKit

private actor RefreshGate {
	private var task: Task<Void, Error>?

	func run(_ body: @Sendable @escaping () async throws -> Void) async throws {
		if let existing = task {
			try await existing.value
			return
		}
		let newTask = Task {
			try await body()
		}
		task = newTask
		defer { task = nil }
		try await newTask.value
	}
}

final class APIClient {
	static let shared = APIClient()

	private let refreshGate = RefreshGate()
	private let jsonDecoder: JSONDecoder = {
		let d = JSONDecoder()
		d.keyDecodingStrategy = .convertFromSnakeCase
		return d
	}()

	private init() {}

	private static let sibUserAgent: String = {
		let device = UIDevice.current
		let name = device.name          // "Alex's iPhone 17"
		let model = device.model        // "iPhone" | "iPad"
		let os = device.systemVersion   // "18.2"
		return "Siberia/1.0 (\(name); \(model); iOS \(os))"
	}()

	func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
		try jsonDecoder.decode(T.self, from: data)
	}

	/// Запрос с опциональными дополнительными заголовками (например `X-Device-ID` при регистрации).
	func request(
		path: String,
		method: String = "GET",
		body: Data? = nil,
		requiresAuth: Bool = true,
		extraHeaders: [String: String] = [:]
	) async throws -> Data {
		try await performRequest(
			path: path,
			method: method,
			body: body,
			requiresAuth: requiresAuth,
			extraHeaders: extraHeaders,
			isRetryAfterRefresh: false
		)
	}

	private func performRequest(
		path: String,
		method: String,
		body: Data?,
		requiresAuth: Bool,
		extraHeaders: [String: String],
		isRetryAfterRefresh: Bool
	) async throws -> Data {
		let base = APIConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		let p = path.hasPrefix("/") ? path : "/" + path
		guard let url = URL(string: base + p) else {
			throw URLError(.badURL)
		}

		var urlRequest = URLRequest(url: url)
		urlRequest.httpMethod = method
		urlRequest.httpBody = body
		urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
		urlRequest.setValue(Self.sibUserAgent, forHTTPHeaderField: "User-Agent")

		for (k, v) in extraHeaders {
			urlRequest.setValue(v, forHTTPHeaderField: k)
		}

		if requiresAuth, let token = TokenStorage.shared.accessToken {
			urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}

		let (data, response) = try await URLSession.shared.data(for: urlRequest)

		guard let http = response as? HTTPURLResponse else {
			throw URLError(.badServerResponse)
		}

		if http.statusCode == 401 && requiresAuth && !isRetryAfterRefresh {
			try await refreshGate.run { try await self.refreshTokens() }
			return try await performRequest(
				path: path,
				method: method,
				body: body,
				requiresAuth: requiresAuth,
				extraHeaders: extraHeaders,
				isRetryAfterRefresh: true
			)
		}

		guard 200..<300 ~= http.statusCode else {
			let msg = parseErrorMessage(data)
			throw APIClientError.httpStatus(http.statusCode, message: msg)
		}

		return data
	}

	private func parseErrorMessage(_ data: Data) -> String? {
		if let env = try? jsonDecoder.decode(APIErrorEnvelope.self, from: data) {
			// Если есть детали по полям — собираем человекочитаемый список
			if let fields = env.error?.fields, !fields.isEmpty {
				return fields.map(\.humanReadable).joined(separator: "\n")
			}
			return env.error?.message
		}
		return String(data: data, encoding: .utf8)
	}

	// MARK: – Multipart upload

	func upload(
		path: String,
		fileData: Data,
		fileName: String,
		mimeType: String,
		extraFields: [String: String] = [:]
	) async throws -> Data {
		let boundary = "SibBoundary-\(UUID().uuidString.prefix(8))"
		var body = Data()

		func append(_ string: String) { body.append(string.data(using: .utf8)!) }

		// File field
		append("--\(boundary)\r\n")
		append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
		append("Content-Type: \(mimeType)\r\n\r\n")
		body.append(fileData)
		append("\r\n")

		// Extra string fields
		for (key, value) in extraFields {
			append("--\(boundary)\r\n")
			append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
			append("\(value)\r\n")
		}

		append("--\(boundary)--\r\n")

		let base = APIConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		let p = path.hasPrefix("/") ? path : "/" + path
		guard let url = URL(string: base + p) else { throw URLError(.badURL) }

		var req = URLRequest(url: url)
		req.httpMethod = "POST"
		req.httpBody = body
		req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
		if let token = TokenStorage.shared.accessToken {
			req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
		}

		let (data, response) = try await URLSession.shared.data(for: req)
		guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
			let code = (response as? HTTPURLResponse)?.statusCode ?? 0
			throw APIClientError.httpStatus(code, message: String(data: data, encoding: .utf8))
		}
		return data
	}

	private func refreshTokens() async throws {
		guard let refresh = TokenStorage.shared.refreshToken else {
			throw APIClientError.refreshFailed
		}

		let body = try JSONSerialization.data(withJSONObject: [
			"refresh_token": refresh,
			"device_id": DeviceIDStorage.shared.deviceId
		])

		let base = APIConfig.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		guard let url = URL(string: base + "/auth/refresh") else {
			throw APIClientError.refreshFailed
		}

		var urlRequest = URLRequest(url: url)
		urlRequest.httpMethod = "POST"
		urlRequest.httpBody = body
		urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

		let (data, response) = try await URLSession.shared.data(for: urlRequest)
		guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
			throw APIClientError.refreshFailed
		}

		let decoded = try jsonDecoder.decode(TokenResponse.self, from: data)
		TokenStorage.shared.accessToken = decoded.accessToken
		TokenStorage.shared.refreshToken = decoded.refreshToken
	}
}
