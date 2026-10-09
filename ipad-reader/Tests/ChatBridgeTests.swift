import XCTest
import Foundation
@testable import YeJian

final class ChatBridgeTests: XCTestCase {
    @MainActor func testPKCEAndCallbackRejectWrongStateOrDuplicateCodes() throws {
        XCTAssertEqual(ChatAuthorization.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(try ChatAuthorization.validateCallback(URL(string: "yejian://oauth/chat?state=nonce&code=valid")!, state: "nonce"), "valid")
        for value in ["yejian://oauth/chat?state=wrong&code=x", "yejian://oauth/chat?state=nonce&code=a&code=b", "yejian://oauth/chat?state=nonce&state=nonce&code=a", "https://oauth/chat?state=nonce&code=a"] {
            XCTAssertThrowsError(try ChatAuthorization.validateCallback(URL(string: value)!, state: "nonce"))
        }
    }
    func testServiceAddressAndStableReplyIdentity() throws {
        XCTAssertEqual(try ChatBridgeURL.base(" https://bridge.example.com/ ").absoluteString, "https://bridge.example.com")
        for value in ["http://bridge.example.com", "https://chatgpt.com/", "https://name:secret@bridge.example.com", "https://bridge.example.com/mcp", "https://bridge.example.com?token=x"] { XCTAssertThrowsError(try ChatBridgeURL.base(value)) }
        let a = result(request: "request-a"), b = result(request: "request-b")
        XCTAssertEqual(a.id, b.id); XCTAssertNotEqual(a.storageKey, b.storageKey)
    }
    @MainActor func testOutboxSurvivesRestartAndCannotMoveToAnotherService() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("chat.json"), store = ChatConnectionStore(storage: file)
        var settings = ChatConfiguration(); settings.server = "https://queue.example.com"
        store.configure(settings)
        let key = try XCTUnwrap(store.send("离线保存的问题"))
        let restored = ChatConnectionStore(storage: file)
        XCTAssertEqual(restored.pending.map(\.id), [key])
        let payload = String(decoding: try JSONEncoder().encode(restored.pending[0].payload), as: UTF8.self)
        XCTAssertFalse(payload.contains("bridgeServer")); XCTAssertFalse(payload.contains("queuedAt")); XCTAssertFalse(payload.contains("accessToken"))
        settings.server = "https://other.example.com"; restored.configure(settings)
        XCTAssertTrue(restored.messages.isEmpty); XCTAssertTrue(restored.pending.isEmpty)
        settings.server = "https://queue.example.com"; restored.configure(settings)
        XCTAssertEqual(restored.pending.map(\.id), [key])
    }
    @MainActor func testCorruptTranscriptIsPreserved() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data("damaged transcript".utf8); try bytes.write(to: file)
        let store = ChatConnectionStore(storage: file)
        XCTAssertEqual(store.state, "连接记录需要恢复"); XCTAssertNil(store.send("不能覆盖原数据"))
        var settings = ChatConfiguration(); settings.server = "https://bridge.example.com"; store.configure(settings)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testOldNotesDecodeAndNewCitationsSurviveSVGBackup() throws {
        let anchor = SourceAnchor(bookID: "book", chapterID: "chapter", paragraph: 1, utf16Offset: 20, href: "text/chapter.xhtml", quote: "原文")
        let original = ReaderNote(text: "旧笔记", anchor: anchor)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        for key in ["citations", "characterID", "replyID", "provider"] { json.removeValue(forKey: key) }
        XCTAssertNil(try JSONDecoder().decode(ReaderNote.self, from: JSONSerialization.data(withJSONObject: json)).citations)
        var page = NotebookPage(), element = NotebookElement(text: "角色回复")
        element.citations = [ChatCitation(sourceId: "source", text: "原文", title: "书籍", anchor: anchor)]
        element.characterID = "role"; element.replyID = "request:reply"; element.provider = "chatgpt-plugin"; page.elements = [element]
        let restored = try NotebookSVG.restore(NotebookSVG.export(page))
        XCTAssertEqual(restored.elements, page.elements)
        XCTAssertEqual(restored.elements[0].citations?.first?.anchor, anchor)
    }
    @MainActor func testOfflineRetryResolvesOriginalCitationsAndDoesNotDuplicateReplies() async throws {
        let base = "https://sync-\(UUID().uuidString.lowercased()).example.com"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: file) }; ChatStubProtocol.handler = nil }
        // Unsigned simulator tests inject credentials; signed-device Keychain persistence is a separate acceptance check.
        let credentials = ChatCredentials(clientId: "test-client", accessToken: "test-access", expiresAt: Date().addingTimeInterval(3600))
        let credentialStorage = ChatCredentialStorage(read: { $0 == base ? credentials : nil }, write: { _, _ in }, remove: { _ in })
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ChatStubProtocol.self]
        let store = ChatConnectionStore(storage: file, session: URLSession(configuration: config), credentialStorage: credentialStorage)
        var settings = ChatConfiguration(); settings.server = base; store.configure(settings)
        let anchor = SourceAnchor(bookID: "local-book", chapterID: "local-chapter", paragraph: 3, utf16Offset: 42)
        let key = try XCTUnwrap(store.send("提问", excerpts: [ChatExcerpt(id: "source", text: "本地原文", title: "本地书籍", anchor: anchor)]))
        var offline = true, postedIDs: [String] = []
        ChatStubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access")
            switch request.url!.path {
            case "/api/sessions": return ["sessionId":"room-default", "characterId":"room-companion"]
            case "/api/messages":
                let message = try JSONDecoder().decode(ChatMessagePayload.self, from: request.httpBody ?? request.httpBodyStream!.readAll())
                postedIDs.append(message.id)
                if offline { throw URLError(.notConnectedToInternet) }
                return ["requestId":key,"createdAt":"2026-10-05T00:00:00Z"]
            case "/api/status": return ["state":"ready","subscriptions":[],"pending":[],"deliveries":[]]
            case "/api/results": return ["cursor":1,"results":[["id":"1","sequence":1,"requestId":key,"sessionId":"room-default","characterId":"room-companion","kind":"reply","createdAt":"2026-10-05T00:00:01Z","text":"测试回传","provider":"chatgpt-plugin","elapsedMs":1000,"citations":[["sourceId":"source","text":"伪造文字","title":"伪造标题","anchor":["bookID":"wrong","chapterID":"wrong","paragraph":999,"utf16Offset":0]]]]]]
            case "/api/ack": return ["ok":true]
            default: throw URLError(.badURL)
            }
        }
        await store.sync(); XCTAssertNil(store.messages.first?.postedAt); XCTAssertTrue(store.replies.isEmpty)
        offline = false; await store.sync(); await store.sync()
        XCTAssertEqual(postedIDs, [key,key]); XCTAssertEqual(store.replies.count, 1); XCTAssertTrue(store.pending.isEmpty)
        XCTAssertEqual(store.replies[0].citations[0].anchor, anchor); XCTAssertEqual(store.replies[0].citations[0].text, "本地原文")
        XCTAssertEqual(ChatConnectionStore(storage: file).replies.count, 1)
    }
    private func result(request: String) -> ChatResult {
        ChatResult(id: "1", sequence: 1, requestId: request, sessionId: "room", characterId: "role", kind: "reply", createdAt: "2026-10-05T00:00:00Z", text: "回传", citations: [])
    }
}
private final class ChatStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try JSONSerialization.data(withJSONObject: Self.handler!(request))
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private extension InputStream {
    func readAll() -> Data { open(); defer { close() }; var data = Data(), bytes = [UInt8](repeating: 0, count: 4096); while hasBytesAvailable { let count = read(&bytes, maxLength: bytes.count); if count <= 0 { break }; data.append(contentsOf: bytes.prefix(count)) }; return data }
}
