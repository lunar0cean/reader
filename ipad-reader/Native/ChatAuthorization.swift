import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit

struct ChatCredentials: Codable {
    var clientId: String; var accessToken: String; var refreshToken: String?
    var expiresAt: Date
}
struct ChatCredentialStorage {
    var read: (String) -> ChatCredentials?
    var write: (ChatCredentials, String) throws -> Void
    var remove: (String) -> Void
    static let keychain = ChatCredentialStorage(read: ChatKeychain.read, write: ChatKeychain.write, remove: ChatKeychain.remove)
}
enum ChatKeychain {
    private static let service = "com.lunar0cean.yejian.chat-bridge"
    static func read(account: String) -> ChatCredentials? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(ChatCredentials.self, from: data)
    }
    static func write(_ value: ChatCredentials, account: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var insert = query; attributes.forEach { insert[$0.key] = $0.value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw ChatBridgeError.message("无法保存连接凭证。") }
        } else if update != errSecSuccess { throw ChatBridgeError.message("无法更新连接凭证。") }
    }
    static func remove(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
struct ChatTokenResponse: Decodable {
    var access_token: String; var refresh_token: String?; var expires_in: Int
    func credentials(client: String, fallbackRefresh: String? = nil) -> ChatCredentials {
        ChatCredentials(clientId: client, accessToken: access_token, refreshToken: refresh_token ?? fallbackRefresh,
                        expiresAt: Date().addingTimeInterval(TimeInterval(expires_in)))
    }
}
@MainActor final class ChatAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var webSession: ASWebAuthenticationSession?
    static let redirect = "yejian://oauth/chat"
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ChatBridgeError.message("无法生成登录验证数据。") }
        return Data(bytes).base64URLEncoded
    }
    static func challenge(_ verifier: String) -> String { Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded }
    static func validateCallback(_ url: URL, state: String) throws -> String {
        guard url.scheme == "yejian", url.host == "oauth", url.path == "/chat",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.queryItems?.filter({ $0.name == "state" }).count == 1,
              parts.queryItems?.first(where: { $0.name == "state" })?.value == state else { throw ChatBridgeError.invalidCallback }
        if let error = parts.queryItems?.first(where: { $0.name == "error" })?.value { throw ChatBridgeError.message("授权未完成：\(error)") }
        guard parts.queryItems?.filter({ $0.name == "code" }).count == 1,
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value, !code.isEmpty else { throw ChatBridgeError.invalidCallback }
        return code
    }
    func open(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "yejian") { [weak self] callback, error in
                Task { @MainActor in self?.webSession = nil }
                if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: error ?? ChatBridgeError.invalidCallback) }
            }
            session.presentationContextProvider = self; session.prefersEphemeralWebBrowserSession = false
            webSession = session
            if !session.start() { webSession = nil; continuation.resume(throwing: ChatBridgeError.message("无法打开系统登录窗口。")) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
extension Data {
    var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}
