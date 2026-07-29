import Foundation

/// Where to send frames. The API key is held separately (Keychain) rather than in
/// this struct's persisted form — see Settings.
struct TronbytConfig: Equatable {
    var baseURL: String
    var deviceID: String
    var installationID: String
    var apiKey: String

    var isConfigured: Bool {
        !baseURL.isEmpty && !deviceID.isEmpty && !apiKey.isEmpty
    }

    /// Trailing slashes on the base URL are common when pasted from a browser and
    /// would otherwise produce a double slash in the path.
    func endpoint() -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(trimmed)/v0/devices/\(deviceID)/push")
    }
}

enum TronbytError: Error, CustomStringConvertible {
    case notConfigured
    case badURL(String)
    case rejected(status: Int, body: String)

    var description: String {
        switch self {
        case .notConfigured:
            return "tronbyt details are incomplete — open Settings"
        case let .badURL(url):
            return "not a usable tronbyt URL: \(url)"
        case let .rejected(status, body):
            return "tronbyt rejected the frame (HTTP \(status))"
                + (body.isEmpty ? "" : ": \(body.prefix(120))")
        }
    }
}

/// Sends encoded frames to a tronbyt-server.
struct TronbytClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Send one frame. Returns the HTTP status on success.
    @discardableResult
    func send(frame: Data, config: TronbytConfig) async throws -> Int {
        guard config.isConfigured else { throw TronbytError.notConfigured }
        guard let url = config.endpoint() else { throw TronbytError.badURL(config.baseURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Note: the raw key, NOT "Bearer <key>" — the tronbyt API takes it bare.
        request.setValue(config.apiKey, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "image": frame.base64EncodedString(),
            "installationID": config.installationID,
        ])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw TronbytError.rejected(status: status,
                                        body: String(data: data, encoding: .utf8) ?? "")
        }
        return status
    }
}
