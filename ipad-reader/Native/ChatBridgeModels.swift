import Foundation

struct ChatConfiguration: Codable, Equatable {
    var server = ""
    var sessionId = "room-default"
    var characterId = "room-companion"
    var characterName = "书房伙伴"
    var persona = "你是一位用中文交流的书房阅读伙伴。可以友好地陪用户聊天，依据用户明确共享的原文解释问题，并标明出处。角色动作仅使用提供的清单。"
    var chatURL = "https://chatgpt.com/"
}
struct ChatExcerpt: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var title: String
    var anchor: SourceAnchor
}
struct ChatCitation: Codable, Equatable {
    var sourceId: String
    var text: String
    var title: String
    var anchor: SourceAnchor
}
struct ChatMessage: Codable, Identifiable {
    var id = UUID().uuidString
    var sessionId: String
    var characterId: String
    var characterName: String
    var persona: String
    var text: String
    var excerpts: [ChatExcerpt] = []
    // Local delivery metadata is never sent as a model instruction.
    var queuedAt = Date()
    var postedAt: Date?
    var validationRound: Int?
    var validationBatch: String?
    var bridgeServer: String?
    var payload: ChatMessagePayload { ChatMessagePayload(id: id, sessionId: sessionId, characterId: characterId, characterName: characterName, persona: persona, text: text, excerpts: excerpts) }
}
struct ChatMessagePayload: Codable {
    var id: String; var sessionId: String; var characterId: String; var characterName: String
    var persona: String; var text: String; var excerpts: [ChatExcerpt]
}
struct ChatResult: Codable, Identifiable {
    var id: String; var sequence: Int; var requestId: String; var sessionId: String; var characterId: String
    var kind: String; var createdAt: String; var text: String; var citations: [ChatCitation]
    var action: String?; var bookId: String?; var provider: String?; var elapsedMs: Double?
    var receivedAt: Date?
    var storageKey: String { "\(requestId):\(kind)" }
}
struct ChatTranscript: Codable {
    var version = 1
    var configuration = ChatConfiguration()
    var requests: [ChatMessage] = []
    var results: [ChatResult] = []
    var cursor = 0
}
struct ChatSyncResponse: Decodable { var results: [ChatResult]; var cursor: Int }
struct ChatStatusResponse: Decodable {
    struct Subscription: Decodable { var id: String; var character_id: String; var expires_at: String }
    struct Pending: Decodable { var id: String; var created_at: String }
    struct Delivery: Decodable { var request_id: String; var attempts: Int; var accepted: Int; var last_error: String? }
    var state: String; var subscriptions: [Subscription]; var pending: [Pending]; var deliveries: [Delivery]
}
enum ChatBridgeError: LocalizedError {
    case invalidServer, invalidCallback, message(String), authorizationRequired
    var errorDescription: String? {
        switch self {
        case .invalidServer: return "请填写连接服务的完整 HTTPS 地址，不要填写 ChatGPT 网址。"
        case .invalidCallback: return "登录回调校验失败，请重新授权。"
        case .message(let message): return message
        case .authorizationRequired: return "连接授权已失效，请重新使用 GitHub 授权。"
        }
    }
}
enum ChatBridgeURL {
    static func base(_ text: String) throws -> URL {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/", host != "chatgpt.com", host != "www.chatgpt.com" else { throw ChatBridgeError.invalidServer }
        parts.path = ""; guard let url = parts.url else { throw ChatBridgeError.invalidServer }; return url
    }
    static func endpoint(_ base: URL, path: String, query: [URLQueryItem] = []) -> URL {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.path = path; parts.queryItems = query.isEmpty ? nil : query; return parts.url!
    }
}
