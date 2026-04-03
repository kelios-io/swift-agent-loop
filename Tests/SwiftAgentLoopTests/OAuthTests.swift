import Testing
import Foundation
@testable import SwiftAgentLoop

@Suite("OAuth Authentication")
struct OAuthTests {

    // MARK: - AuthCredential

    @Test("API key credential is Sendable")
    func apiKeyCredential() {
        let cred = AuthCredential.apiKey("sk-test-123")
        if case .apiKey(let key) = cred {
            #expect(key == "sk-test-123")
        } else {
            Issue.record("Expected apiKey credential")
        }
    }

    @Test("OAuth credential wraps token manager")
    func oauthCredential() async {
        let tokens = OAuthTokens(
            accessToken: "access-123",
            refreshToken: "refresh-456",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let manager = OAuthTokenManager(tokens: tokens)
        let cred = AuthCredential.oauth(manager)

        if case .oauth(let m) = cred {
            let current = await m.currentTokens()
            #expect(current.accessToken == "access-123")
        } else {
            Issue.record("Expected oauth credential")
        }
    }

    // MARK: - OAuthTokens

    @Test("OAuthTokens default scope")
    func tokensDefaultScope() {
        let tokens = OAuthTokens(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date()
        )
        #expect(tokens.scope == "user:inference user:profile")
    }

    @Test("OAuthTokens custom scope")
    func tokensCustomScope() {
        let tokens = OAuthTokens(
            accessToken: "a",
            refreshToken: "r",
            expiresAt: Date(),
            scope: "user:inference"
        )
        #expect(tokens.scope == "user:inference")
    }

    // MARK: - OAuthTokenManager

    @Test("Valid token returned when not expired")
    func validTokenNotExpired() async throws {
        let tokens = OAuthTokens(
            accessToken: "valid-token",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600) // 1 hour from now
        )
        let manager = OAuthTokenManager(tokens: tokens)

        let token = try await manager.validAccessToken()
        #expect(token == "valid-token")
    }

    @Test("Current tokens returns snapshot")
    func currentTokensSnapshot() async {
        let tokens = OAuthTokens(
            accessToken: "snap-token",
            refreshToken: "snap-refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let manager = OAuthTokenManager(tokens: tokens)

        let current = await manager.currentTokens()
        #expect(current.accessToken == "snap-token")
        #expect(current.refreshToken == "snap-refresh")
    }

    // MARK: - TokenRefreshResponse Decoding

    @Test("Token refresh response decodes snake_case JSON")
    func decodeRefreshResponse() throws {
        let json = """
        {
            "access_token": "new-access",
            "refresh_token": "new-refresh",
            "expires_in": 3600
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TokenRefreshResponse.self, from: json)
        #expect(response.accessToken == "new-access")
        #expect(response.refreshToken == "new-refresh")
        #expect(response.expiresIn == 3600)
    }

    // MARK: - OAuthError

    @Test("OAuthError cases are descriptive")
    func oauthErrors() {
        let invalid = OAuthError.invalidResponse
        let failed = OAuthError.refreshFailed(statusCode: 403, message: "Forbidden")

        #expect(String(describing: invalid).contains("invalidResponse"))
        #expect(String(describing: failed).contains("403"))
    }

    // MARK: - AnthropicClient with credential

    @Test("AnthropicClient accepts API key credential")
    func clientApiKeyCredential() {
        let _ = AnthropicClient(credential: .apiKey("sk-test"))
        // No crash = success — actor init is the test
    }

    @Test("AnthropicClient convenience init still works")
    func clientConvenienceInit() {
        let _ = AnthropicClient(apiKey: "sk-test")
    }

    @Test("AnthropicClient accepts OAuth credential")
    func clientOAuthCredential() {
        let tokens = OAuthTokens(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let manager = OAuthTokenManager(tokens: tokens)
        let _ = AnthropicClient(credential: .oauth(manager))
    }

    // MARK: - NativeTransport with credential

    @Test("NativeTransport withDefaultTools accepts credential")
    func transportCredential() {
        let _ = NativeTransport.withDefaultTools(credential: .apiKey("sk-test"))
    }

    @Test("NativeTransport withDefaultTools API key convenience still works")
    func transportApiKeyConvenience() {
        let _ = NativeTransport.withDefaultTools(apiKey: "sk-test")
    }

    @Test("NativeTransport init accepts credential")
    func transportInitCredential() {
        let tokens = OAuthTokens(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600)
        )
        let manager = OAuthTokenManager(tokens: tokens)
        let _ = NativeTransport(credential: .oauth(manager))
    }
}
