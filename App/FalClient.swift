import Foundation

/// The two fal.ai calls Mane makes.
enum FalClient {
    /// Live model (WebRTC, ~2¢/s while connected).
    static let liveEndpoint = "decart/lucy-2-6/realtime"
    /// Photo model used when the live stream can't start (~4¢ per photo).
    static let photoEndpoint = "fal-ai/nano-banana/edit"

    struct Failure: Error, CustomStringConvertible {
        let status: Int
        let detail: String
        var description: String { "fal \(status): \(detail)" }
        /// The key is wrong or the account can't pay: no point trying anything else.
        var isAccountProblem: Bool {
            status == 401 || status == 403
                || detail.range(of: "balance|locked|unauthori|invalid key|credentials", options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// A short-lived token for the realtime socket (the key itself never goes to the web page).
    static func realtimeToken(key: String) async throws -> String {
        let alias = liveEndpoint.split(separator: "/")[1]
        let body: [String: Any] = ["allowed_apps": [String(alias)], "token_expiration": 120]
        let data = try await post("https://rest.fal.ai/tokens/", key: key, body: body, timeout: 20)
        if let token = try? JSONDecoder().decode(String.self, from: data) { return token }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = obj["detail"] as? String { return token }
        throw Failure(status: 0, detail: "unexpected token reply")
    }

    /// Edits a square photo (a data: URL) and returns the edited JPEG.
    static func editPhoto(key: String, imageDataURL: String, prompt: String) async throws -> Data {
        let body: [String: Any] = [
            "prompt": prompt,
            "image_urls": [imageDataURL],
            "num_images": 1,
            "output_format": "jpeg",
            "aspect_ratio": "1:1",
        ]
        let data = try await post("https://fal.run/" + photoEndpoint, key: key, body: body, timeout: 90)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = obj["images"] as? [[String: Any]],
              let urlString = images.first?["url"] as? String
        else { throw Failure(status: 0, detail: "no image in reply") }
        if urlString.hasPrefix("data:"), let comma = urlString.firstIndex(of: ","),
           let decoded = Data(base64Encoded: String(urlString[urlString.index(after: comma)...])) {
            return decoded
        }
        guard let url = URL(string: urlString) else { throw Failure(status: 0, detail: "bad image url") }
        let (img, resp) = try await URLSession.shared.data(from: url)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure(status: http.statusCode, detail: "image download failed")
        }
        return img
    }

    private static func post(_ urlString: String, key: String, body: [String: Any], timeout: TimeInterval) async throws -> Data {
        var req = URLRequest(url: URL(string: urlString)!, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Key " + key, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var detail = String(data: data, encoding: .utf8) ?? ""
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let d = obj["detail"] as? String { detail = d }
                else if let d = obj["detail"] { detail = "\(d)" }
            }
            throw Failure(status: status, detail: String(detail.prefix(300)))
        }
        return data
    }
}
