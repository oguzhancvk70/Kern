import Foundation
import Security

// Anthropic Messages API (ham HTTP + SSE); anahtar Keychain'de
enum AIKey {
    private static let service = "dev.kern.anthropic"

    static func load() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func save(_ key: String) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

enum AIModel {
    static let inline = "claude-haiku-4-5"
    static let chat = "claude-sonnet-5"
    static let agent = "claude-opus-5"
}

enum AIError: LocalizedError {
    case noKey, http(Int, String), refusal(String), stream(String)
    var errorDescription: String? {
        switch self {
        case .noKey: return "No Anthropic API key. Use “AI: Set API Key…” or set ANTHROPIC_API_KEY."
        case let .http(code, msg): return "API error \(code): \(msg)"
        case let .refusal(why): return "The request was declined\(why.isEmpty ? "" : ": \(why)")."
        case let .stream(msg): return msg
        }
    }
}

// akıştan yeniden kurulan yanıt
struct AIResponse {
    var content: [[String: Any]] = []
    var stopReason = ""
    var stopDetails: [String: Any]?

    var text: String { content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined() }
    var toolUses: [[String: Any]] { content.filter { $0["type"] as? String == "tool_use" } }
}

// SSE olaylarını içerik bloklarına işler (metin, düşünme, araç girdisi)
struct SSEAccumulator {
    var response = AIResponse()
    private var partialJSON: [Int: String] = [:]
    var onText: ((String) -> Void)?

    mutating func handle(_ event: [String: Any]) throws {
        switch event["type"] as? String {
        case "content_block_start":
            guard let i = event["index"] as? Int, var block = event["content_block"] as? [String: Any] else { return }
            if block["type"] as? String == "tool_use" { block["input"] = [String: Any](); partialJSON[i] = "" }
            while response.content.count <= i { response.content.append([:]) }
            response.content[i] = block
        case "content_block_delta":
            guard let i = event["index"] as? Int, i < response.content.count, let d = event["delta"] as? [String: Any] else { return }
            switch d["type"] as? String {
            case "text_delta":
                let t = d["text"] as? String ?? ""
                response.content[i]["text"] = (response.content[i]["text"] as? String ?? "") + t
                onText?(t)
            case "thinking_delta":
                response.content[i]["thinking"] = (response.content[i]["thinking"] as? String ?? "") + (d["thinking"] as? String ?? "")
            case "signature_delta":
                response.content[i]["signature"] = d["signature"] as? String ?? ""
            case "input_json_delta":
                partialJSON[i, default: ""] += d["partial_json"] as? String ?? ""
            default: break
            }
        case "content_block_stop":
            guard let i = event["index"] as? Int, let raw = partialJSON.removeValue(forKey: i) else { return }
            // eksik/geçersiz JSON: araç çalıştırılmadan hata olarak geri döner
            if raw.isEmpty {
                response.content[i]["input"] = [String: Any]()
            } else if let obj = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                response.content[i]["input"] = obj
            } else {
                response.content[i]["input"] = [String: Any]()
                response.content[i]["_invalid"] = true
            }
        case "message_delta":
            if let d = event["delta"] as? [String: Any] {
                if let r = d["stop_reason"] as? String { response.stopReason = r }
                if let sd = d["stop_details"] as? [String: Any] { response.stopDetails = sd }
            }
        case "error":
            let e = event["error"] as? [String: Any]
            throw AIError.stream(e?["message"] as? String ?? "stream error")
        default: break
        }
    }
}

final class AIClient {
    // test için değiştirilebilir: istek → SSE satırları
    typealias Transport = (URLRequest) -> AsyncThrowingStream<String, Error>
    var transport: Transport = AIClient.urlSession
    var keyProvider: () -> String? = AIKey.load

    static func urlSession(_ req: URLRequest) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    if code != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        let msg = ((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any])
                            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? body
                        throw AIError.http(code, msg)
                    }
                    for try await line in bytes.lines { cont.yield(line) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    // akışlı istek; metin parçaları onText ile gelir
    func stream(_ body: [String: Any], betas: [String] = [], onText: @escaping (String) -> Void) async throws -> AIResponse {
        guard let key = keyProvider(), !key.isEmpty else { throw AIError.noKey }
        var body = body
        body["stream"] = true
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty { req.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        var acc = SSEAccumulator()
        acc.onText = onText
        for try await line in transport(req) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            try acc.handle(obj)
        }
        if acc.response.stopReason == "refusal" {
            throw AIError.refusal(acc.response.stopDetails?["explanation"] as? String ?? "")
        }
        return acc.response
    }
}
