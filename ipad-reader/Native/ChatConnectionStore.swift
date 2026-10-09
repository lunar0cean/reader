import Foundation
import SwiftUI
import UIKit

@MainActor final class ChatConnectionStore: ObservableObject {
    @Published private(set) var transcript: ChatTranscript
    @Published private(set) var state = "未连接"
    @Published private(set) var detail = "填写云端服务地址后，使用 GitHub 授权。"
    @Published private(set) var isAuthorizing = false
    @Published private(set) var isValidating = false
    private let storage: URL
    private let session: URLSession
    private let credentialStorage: ChatCredentialStorage
    private let authorizer = ChatAuthorization()
    private var credentials: ChatCredentials?
    private var polling: Task<Void, Never>?
    private var active = false
    private var synchronizing = false
    private var refreshing: Task<ChatCredentials, Error>?
    private var recoveryBlocked = false
    private var connectionRevision = UUID()
    init(storage: URL? = nil, session: URLSession? = nil, credentialStorage: ChatCredentialStorage = .keychain) {
        self.credentialStorage = credentialStorage
        self.storage = storage ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("chat-transcript.json")
        if let bytes = try? Data(contentsOf: self.storage) {
            do { transcript = try JSONDecoder().decode(ChatTranscript.self, from: bytes) }
            catch { transcript = ChatTranscript(); recoveryBlocked = true }
        } else { transcript = ChatTranscript() }
        if let session { self.session = session }
        else { let c = URLSessionConfiguration.ephemeral; c.httpShouldSetCookies = false; c.timeoutIntervalForRequest = 25; self.session = URLSession(configuration: c) }
        credentials = credentialStorage.read(transcript.configuration.server)
        if recoveryBlocked { state = "连接记录需要恢复"; detail = "原文件保留，暂不覆盖。可以先导出诊断。" }
    }
    var configuration: ChatConfiguration { transcript.configuration }
    var replies: [ChatResult] { transcript.results.filter { result in messages.contains { $0.id == result.requestId } } }
    var messages: [ChatMessage] { transcript.requests.filter { $0.sessionId == configuration.sessionId && $0.characterId == configuration.characterId && $0.bridgeServer == configuration.server } }
    var hasCredentials: Bool { credentials != nil }
    var pending: [ChatMessage] { messages.filter { message in !replies.contains(where: { $0.requestId == message.id && $0.kind == "reply" }) } }
    var setupPrompt: String {
        "请使用阅读器插件订阅 message.created，过滤条件 session_id=\(configuration.sessionId)、character_id=\(configuration.characterId)。收到消息后，用 get_context 读取请求；需要引用时调用 read_excerpts。按照用户要求扮演\(configuration.characterName)，并用 publish_reply 回传完整中文回复，request_id 必须取自事件，citations 只能填共享出处 ID。需要整理笔记时调用 create_note_draft。请关闭消息批处理，以逐条处理问题。"
    }
    func configure(_ value: ChatConfiguration) {
        guard !isAuthorizing, !isValidating else { return }
        do {
            let base = try ChatBridgeURL.base(value.server)
            guard !value.sessionId.isEmpty, !value.characterId.isEmpty, !value.characterName.isEmpty, !value.persona.isEmpty else { throw ChatBridgeError.message("请填写角色与会话信息。") }
            var updated = value; updated.server = base.absoluteString
            let previous = transcript
            if updated.server != configuration.server || updated.sessionId != configuration.sessionId || updated.characterId != configuration.characterId { transcript.cursor = 0 }
            transcript.configuration = updated
            do { try save() } catch { transcript = previous; throw error }
            connectionRevision = UUID(); refreshing?.cancel(); refreshing = nil
            credentials = credentialStorage.read(updated.server); detail = "设置已保存。"; restart()
        } catch is CancellationError { }
        catch { report(error) }
    }
    func setActive(_ value: Bool) { active = value; if value { restart() } else { polling?.cancel(); polling = nil } }
    func disconnect() {
        connectionRevision = UUID()
        polling?.cancel(); polling = nil; refreshing?.cancel(); refreshing = nil
        credentialStorage.remove(configuration.server); credentials = nil
        state = "未连接"; detail = "本地对话保留。可在 ChatGPT 中停止订阅，以撤销角色监控。"
    }
    func authorize() async {
        guard !isAuthorizing, !recoveryBlocked else { return }
        isAuthorizing = true; polling?.cancel(); state = "待授权"; defer { isAuthorizing = false; restart() }
        do {
            let revision = connectionRevision
            let base = try ChatBridgeURL.base(configuration.server)
            struct Client: Decodable { var client_id: String }
            let client: Client = try await perform(base: base, path: "/register", method: "POST", payload: [
                "client_name": "阅读器 iPad", "redirect_uris": [ChatAuthorization.redirect], "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"], "token_endpoint_auth_method": "none"
            ], authorized: false)
            let verifier = try ChatAuthorization.random(), nonce = try ChatAuthorization.random()
            let url = ChatBridgeURL.endpoint(base, path: "/authorize", query: [
                URLQueryItem(name: "client_id", value: client.client_id), URLQueryItem(name: "redirect_uri", value: ChatAuthorization.redirect),
                URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "state", value: nonce),
                URLQueryItem(name: "scope", value: "bridge:read bridge:write offline_access"), URLQueryItem(name: "resource", value: base.absoluteString),
                URLQueryItem(name: "code_challenge", value: ChatAuthorization.challenge(verifier)), URLQueryItem(name: "code_challenge_method", value: "S256")
            ])
            let callback = try await authorizer.open(url), code = try ChatAuthorization.validateCallback(callback, state: nonce)
            let value = try await token(base: base, fields: ["grant_type": "authorization_code", "client_id": client.client_id,
                "code": code, "code_verifier": verifier, "redirect_uri": ChatAuthorization.redirect, "resource": base.absoluteString])
                .credentials(client: client.client_id)
            guard revision == connectionRevision else { throw CancellationError() }
            try credentialStorage.write(value, configuration.server); credentials = value
            try await initializeSession(); detail = "App 已授权。请在 ChatGPT Work 中连接插件并订阅当前会话。"
        } catch { report(error) }
    }
    func send(_ text: String, excerpts: [ChatExcerpt] = [], validationRound: Int? = nil, validationBatch: String? = nil) -> String? {
        guard !recoveryBlocked, !configuration.server.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let message = ChatMessage(sessionId: configuration.sessionId, characterId: configuration.characterId, characterName: configuration.characterName,
                                  persona: configuration.persona, text: text, excerpts: excerpts, validationRound: validationRound, validationBatch: validationBatch, bridgeServer: configuration.server)
        transcript.requests.append(message)
        do { try save(); restart(); return message.id }
        catch { transcript.requests.removeAll { $0.id == message.id }; report(error); return nil }
    }
    private func save() throws {
        guard !recoveryBlocked else { throw ChatBridgeError.message("连接记录损坏，原文件未覆盖。") }
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(transcript).write(to: storage, options: .atomic)
    }
    private func restart() {
        polling?.cancel(); polling = nil
        guard active, !isAuthorizing, !recoveryBlocked else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active else { return }
                await self.sync()
                let interval: UInt64 = self.pending.isEmpty ? 30 : 2
                do { try await Task.sleep(nanoseconds: interval * 1_000_000_000) } catch { return }
            }
        }
    }
    func sync() async {
        guard !synchronizing, !recoveryBlocked else { return }; synchronizing = true; defer { synchronizing = false }
        guard credentials != nil else { state = "未连接"; return }
        do {
            let base = try ChatBridgeURL.base(configuration.server)
            try await initializeSession()
            for message in pending where message.postedAt == nil {
                struct Posted: Decodable { var requestId: String; var createdAt: String }
                let _: Posted = try await perform(base: base, path: "/api/messages", method: "POST", data: JSONEncoder().encode(message.payload))
                if let index = transcript.requests.firstIndex(where: { $0.id == message.id }) { transcript.requests[index].postedAt = Date() }; try save()
            }
            let status: ChatStatusResponse = try await perform(base: base, path: "/api/status", query: [URLQueryItem(name: "sessionId", value: configuration.sessionId)])
            let response: ChatSyncResponse = try await perform(base: base, path: "/api/results", query: [URLQueryItem(name: "sessionId", value: configuration.sessionId), URLQueryItem(name: "after", value: String(transcript.cursor))])
            let previous = transcript
            for var result in response.results where result.sessionId == configuration.sessionId && result.characterId == configuration.characterId {
                guard let original = messages.first(where: { $0.id == result.requestId }), !transcript.results.contains(where: { $0.storageKey == result.storageKey }) else { continue }
                // Resolve citations against the original local snapshot, never against model-created coordinates.
                result.citations = result.citations.compactMap { citation in
                    guard let e = original.excerpts.first(where: { $0.id == citation.sourceId }) else { return nil }
                    return ChatCitation(sourceId: e.id, text: e.text, title: e.title, anchor: e.anchor)
                }
                result.receivedAt = Date(); transcript.results.append(result)
            }
            transcript.cursor = max(transcript.cursor, response.cursor)
            do { try save() } catch { transcript = previous; throw error }
            struct Ack: Decodable { var ok: Bool }
            let _: Ack = try await perform(base: base, path: "/api/ack", method: "POST", payload: ["sessionId": configuration.sessionId, "cursor": transcript.cursor])
            if status.state != "ready" { state = "待订阅"; detail = "App 已授权，ChatGPT Work 尚未订阅此角色。复制设置提示词到 Work 对话。" }
            else if !pending.isEmpty {
                state = "等待回复"
                let expired = pending.contains { Date().timeIntervalSince($0.postedAt ?? $0.queuedAt) >= 60 }
                detail = expired ? "等待已超过一分钟；迟到回复仍会保存到原问题。" : "消息已保存，等待角色通过插件回传。"
                if let failure = status.deliveries.first(where: { $0.last_error != nil })?.last_error { detail += " 投递：\(failure)" }
            } else { state = "可用"; detail = "角色已订阅，App 可以接收回复。" }
        } catch is CancellationError { }
        catch { if !Task.isCancelled { report(error) } }
    }
    private func initializeSession() async throws {
        struct SessionResult: Decodable { var sessionId: String; var characterId: String }
        let c = configuration
        let _: SessionResult = try await perform(base: ChatBridgeURL.base(c.server), path: "/api/sessions", method: "POST",
            payload: ["sessionId": c.sessionId, "characterId": c.characterId, "characterName": c.characterName, "persona": c.persona])
    }
    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = credentials else { throw ChatBridgeError.authorizationRequired }
        if !forceRefresh && current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        if let refreshing { return try await refreshing.value.accessToken }
        guard let refresh = current.refreshToken else { throw ChatBridgeError.authorizationRequired }
        let base = try ChatBridgeURL.base(configuration.server), account = configuration.server
        let revision = connectionRevision
        let task = Task { [self] in
            let result = try await token(base: base, fields: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": current.clientId, "resource": base.absoluteString])
            let value = result.credentials(client: current.clientId, fallbackRefresh: refresh)
            guard revision == connectionRevision, !Task.isCancelled else { throw CancellationError() }
            try credentialStorage.write(value, account); return value
        }
        refreshing = task; defer { if revision == connectionRevision { refreshing = nil } }
        let value = try await task.value
        guard revision == connectionRevision else { throw CancellationError() }
        credentials = value; return value.accessToken
    }
    private func token(base: URL, fields: [String: String]) async throws -> ChatTokenResponse {
        var request = URLRequest(url: ChatBridgeURL.endpoint(base, path: "/token")); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var parts = URLComponents(); parts.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return try await decode(request)
    }
    private func perform<T: Decodable>(base: URL, path: String, method: String = "GET", query: [URLQueryItem] = [], payload: [String: Any]? = nil, data: Data? = nil, authorized: Bool = true) async throws -> T {
        let revision = connectionRevision
        var request = URLRequest(url: ChatBridgeURL.endpoint(base, path: path, query: query)); request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept"); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try data ?? payload.map { try JSONSerialization.data(withJSONObject: $0) }
        if authorized { request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization") }
        guard revision == connectionRevision else { throw CancellationError() }
        do {
            let value: T = try await decode(request)
            guard revision == connectionRevision else { throw CancellationError() }
            return value
        }
        catch ChatBridgeError.authorizationRequired where authorized {
            guard revision == connectionRevision else { throw CancellationError() }
            request.setValue("Bearer \(try await accessToken(forceRefresh: true))", forHTTPHeaderField: "Authorization")
            let value: T = try await decode(request)
            guard revision == connectionRevision else { throw CancellationError() }
            return value
        }
    }
    private func decode<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatBridgeError.message("连接服务没有返回 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw ChatBridgeError.authorizationRequired }
            let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw ChatBridgeError.message(value?["error"] as? String ?? "连接失败：HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func report(_ error: Error) { state = "连接异常"; detail = error.localizedDescription }
    func validateTenRounds() async {
        guard !isValidating, state == "可用" else { return }; isValidating = true; defer { isValidating = false }
        let batch = UUID().uuidString
        for round in 1...10 {
            guard active, !Task.isCancelled, let key = send("连接验证第 \(round) 轮。请以角色身份简短回应，并用 publish_reply 回传这条消息的 request_id。", validationRound: round, validationBatch: batch) else { return }
            let start = Date()
            while active && Date().timeIntervalSince(start) < 60 && !Task.isCancelled {
                if replies.contains(where: { $0.requestId == key && $0.kind == "reply" }) { break }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
            guard replies.contains(where: { $0.requestId == key && $0.kind == "reply" }) else { state = "验证未通过"; detail = "第 \(round) 轮一分钟内未收到回复；请检查 Work 对话和事件投递。"; return }
        }
        detail = "十轮已收到回传，请导出诊断并核对耗时与操作记录。"
    }
    func exportDiagnostics() -> URL? {
        let batch = messages.last(where: { $0.validationBatch != nil })?.validationBatch
        let rounds: [[String: Any]] = messages.filter { $0.validationRound != nil && $0.validationBatch == batch }.map { message in
            let reply = replies.first { $0.requestId == message.id && $0.kind == "reply" }
            let appElapsed = reply?.receivedAt.map { $0.timeIntervalSince(message.queuedAt) * 1000 }
            return ["round": message.validationRound ?? 0, "requestId": message.id, "received": reply != nil,
                    "elapsedMs": reply?.elapsedMs ?? -1, "appElapsedMs": appElapsed ?? -1, "withinOneMinute": (appElapsed ?? .infinity) <= 60000]
        }
        let report: [String: Any] = ["engine": "yejian-chat-diagnostics-v1", "state": state, "detail": detail,
            "server": configuration.server, "sessionId": configuration.sessionId, "characterId": configuration.characterId,
            "systemVersion": UIDevice.current.systemVersion, "device": UIDevice.current.model, "modelAPI": false,
            "rounds": rounds, "replyChainPassed": rounds.count == 10 && rounds.allSatisfy { $0["withinOneMinute"] as? Bool == true },
            "accountWorkVerified": "需在验收表确认真实 ChatGPT Work 环境，本报告仅记录 App 收到的消息。",
            "manualActions": "需用户在验收表记录登录、确认及是否关闭聊天网页；本报告不推断这些操作。"]
        do { let url = FileManager.default.temporaryDirectory.appendingPathComponent("阅读器-连接诊断.json"); try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic); return url }
        catch { self.report(error); return nil }
    }
}
