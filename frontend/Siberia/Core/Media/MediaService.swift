import Foundation

final class MediaService {
	static let shared = MediaService()
	private init() {}

	private let decoder: JSONDecoder = {
		let d = JSONDecoder()
		d.keyDecodingStrategy = .convertFromSnakeCase
		return d
	}()

	// Upload a file. type must match backend MediaType enum values.
	func upload(
		data: Data,
		fileName: String,
		mimeType: String,
		type: String,
		durationSec: Int? = nil,
		waveform: [Float]? = nil
	) async throws -> MediaUploadResponse {
		var fields: [String: String] = ["type": type]
		if let dur = durationSec { fields["duration_sec"] = "\(dur)" }
		if let w = waveform, !w.isEmpty {
			// Сериализуем массив амплитуд в JSON для multipart-формы
			if let jsonData = try? JSONSerialization.data(withJSONObject: w),
			   let jsonStr = String(data: jsonData, encoding: .utf8) {
				fields["waveform"] = jsonStr
			}
		}
		let raw = try await APIClient.shared.upload(
			path: "/media/upload",
			fileData: data,
			fileName: fileName,
			mimeType: mimeType,
			extraFields: fields
		)
		return try decoder.decode(MediaUploadResponse.self, from: raw)
	}

	// Returns presigned URL only (backward compat).
	func getURL(mediaId: String) async throws -> String {
		return try await getMeta(mediaId: mediaId).url
	}

	// Returns the full media metadata including presigned URL, original name, MIME, etc.
	func getMeta(mediaId: String) async throws -> MediaURLResponse {
		let data = try await APIClient.shared.request(path: "/media/\(mediaId)/url")
		return try decoder.decode(MediaURLResponse.self, from: data)
	}
}
