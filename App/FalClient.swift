import Foundation

/// fal.ai calls made natively. (Eden Live's session calls go through FalBridge.)
enum FalClient {
    /// Lucy, the second live engine (WebRTC, ~2¢/s while connected).
    static let liveEndpoint = "decart/lucy-2-6/realtime"

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
