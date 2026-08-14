import CryptoKit
import Foundation
import Testing
@testable import SwiftAgentLoop

@Suite("MCPOAuthClient")
struct MCPOAuthClientTests {
    // MARK: Units

    @Test("PKCE S256 challenge matches the RFC 7636 vector")
    func pkceVector() {
        #expect(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    @Test("Verifier is base64url and long enough")
    func verifierShape() {
        let verifier = PKCE.generateVerifier()
        #expect(verifier.count >= 43)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        #expect(verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
    }

    @Test("resource_metadata is extracted from WWW-Authenticate")
    func wwwAuthenticateParsing() {
        let header = #"Bearer realm="mcp", resource_metadata="https://hub.test/.well-known/oauth-protected-resource", error="invalid_token""#
        #expect(
            MCPOAuthClient.resourceMetadataURL(fromWWWAuthenticate: header)
                == URL(string: "https://hub.test/.well-known/oauth-protected-resource")
        )
        #expect(MCPOAuthClient.resourceMetadataURL(fromWWWAuthenticate: "Bearer realm=\"x\"") == nil)
    }

    // MARK: Full flow

    @Test("authorize: discovery → registration → PKCE flow → token exchange")
    func fullAuthorizeFlow() async throws {
        let host = "oauth-flow.test"
        let resource = URL(string: "https://\(host)/mcp")!
        let registrations = TestBox(0)
        let capturedAuthURL = TestBox<URL?>(nil)
        let exchangedVerifier = TestBox<String?>(nil)

        MockHTTP.register(host: host) { request in
            switch request.url!.path {
            case "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource":
                return (200, HubFixture.jsonHeaders(), HubFixture.protectedResourceMetadata(host: host))
            case "/.well-known/oauth-authorization-server":
                return (200, HubFixture.jsonHeaders(), HubFixture.authorizationServerMetadata(host: host))
            case "/auth/oauth/register":
                registrations.withLock { $0 += 1 }
                return (201, HubFixture.jsonHeaders(), Data(#"{"client_id":"c-123"}"#.utf8))
            case "/auth/oauth/token":
                let fields = request.formFields
                exchangedVerifier.value = fields["code_verifier"]
                guard fields["grant_type"] == "authorization_code",
                      fields["code"] == "test-code",
                      fields["client_id"] == "c-123" else {
                    return (400, HubFixture.jsonHeaders(), Data(#"{"error":"invalid_grant"}"#.utf8))
                }
                return (200, HubFixture.jsonHeaders(), Data(
                    #"{"access_token":"at-1","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-1","scope":"tools:execute"}"#.utf8
                ))
            default:
                return (404, [:], Data())
            }
        }

        let store = MemoryOAuthStore()
        let client = MCPOAuthClient(
            configuration: MCPOAuthConfiguration(
                clientName: "laplace-test",
                redirectURI: URL(string: "laplace://oauth-callback")!
            ),
            store: store,
            presenter: AutoApprovePresenter(captured: capturedAuthURL),
            session: MockHTTP.makeSession()
        )

        let token = try await client.authorize(resource: resource)
        #expect(token == "at-1")
        #expect(registrations.value == 1)

        // The verifier sent to the token endpoint must hash to the challenge in
        // the authorization URL — otherwise PKCE is decorative.
        let authURL = try #require(capturedAuthURL.value)
        let items = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let verifier = try #require(exchangedVerifier.value)
        #expect(query("code_challenge") == PKCE.challenge(for: verifier))
        #expect(query("code_challenge_method") == "S256")
        #expect(query("client_id") == "c-123")
        #expect(query("resource") == resource.absoluteString)
        // No explicit scopes configured → the server's advertised set is requested.
        #expect(query("scope") == "tools:execute resources:read prompts:read")

        let saved = try #require(store.all[resource])
        #expect(saved.clientID == "c-123")
        #expect(saved.accessToken == "at-1")
        #expect(saved.refreshToken == "rt-1")
        #expect(saved.tokenEndpoint == URL(string: "https://\(host)/auth/oauth/token"))

        // A usable token is now returned without any interaction.
        #expect(try await client.validAccessToken(resource: resource) == "at-1")
    }

    @Test("authorize reuses a stored client registration")
    func reusesRegistration() async throws {
        let host = "oauth-reuse.test"
        let resource = URL(string: "https://\(host)/mcp")!
        let registrations = TestBox(0)

        MockHTTP.register(host: host) { request in
            switch request.url!.path {
            case "/.well-known/oauth-protected-resource/mcp":
                return (200, HubFixture.jsonHeaders(), HubFixture.protectedResourceMetadata(host: host))
            case "/.well-known/oauth-authorization-server":
                return (200, HubFixture.jsonHeaders(), HubFixture.authorizationServerMetadata(host: host))
            case "/auth/oauth/register":
                registrations.withLock { $0 += 1 }
                return (201, HubFixture.jsonHeaders(), Data(#"{"client_id":"c-new"}"#.utf8))
            case "/auth/oauth/token":
                return (200, HubFixture.jsonHeaders(), Data(#"{"access_token":"at-2","token_type":"Bearer"}"#.utf8))
            default:
                return (404, [:], Data())
            }
        }

        let store = MemoryOAuthStore(preloaded: [resource: MCPOAuthState(clientID: "c-existing")])
        let client = MCPOAuthClient(
            configuration: MCPOAuthConfiguration(redirectURI: URL(string: "laplace://oauth-callback")!),
            store: store,
            presenter: AutoApprovePresenter(),
            session: MockHTTP.makeSession()
        )

        _ = try await client.authorize(resource: resource)
        #expect(registrations.value == 0)
        #expect(store.all[resource]?.clientID == "c-existing")
    }

    // MARK: Refresh

    @Test("Expired token refreshes proactively and rotates the refresh token")
    func refreshRotation() async throws {
        let host = "oauth-refresh.test"
        let resource = URL(string: "https://\(host)/mcp")!
        let refreshCalls = TestBox(0)

        MockHTTP.register(host: host) { request in
            guard request.url!.path == "/auth/oauth/token" else { return (404, [:], Data()) }
            let fields = request.formFields
            refreshCalls.withLock { $0 += 1 }
            guard fields["grant_type"] == "refresh_token", fields["refresh_token"] == "rt-old" else {
                return (400, HubFixture.jsonHeaders(), Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            return (200, HubFixture.jsonHeaders(), Data(
                #"{"access_token":"at-new","token_type":"Bearer","expires_in":3600,"refresh_token":"rt-new"}"#.utf8
            ))
        }

        let store = MemoryOAuthStore(preloaded: [resource: MCPOAuthState(
            clientID: "c-1",
            accessToken: "at-old",
            refreshToken: "rt-old",
            expiresAt: Date(timeIntervalSinceNow: -10),
            tokenEndpoint: URL(string: "https://\(host)/auth/oauth/token")
        )])
        let client = MCPOAuthClient(
            configuration: MCPOAuthConfiguration(redirectURI: URL(string: "laplace://oauth-callback")!),
            store: store,
            presenter: AutoApprovePresenter(),
            session: MockHTTP.makeSession()
        )

        #expect(try await client.validAccessToken(resource: resource) == "at-new")
        #expect(refreshCalls.value == 1)
        let saved = try #require(store.all[resource])
        #expect(saved.refreshToken == "rt-new")
        #expect((saved.expiresAt ?? .distantPast) > Date())

        // Fresh again — no second refresh.
        #expect(try await client.validAccessToken(resource: resource) == "at-new")
        #expect(refreshCalls.value == 1)
    }

    @Test("A rejected refresh clears tokens but keeps the registration")
    func refreshRejectionClearsTokens() async throws {
        let host = "oauth-refresh-dead.test"
        let resource = URL(string: "https://\(host)/mcp")!

        MockHTTP.register(host: host) { request in
            guard request.url!.path == "/auth/oauth/token" else { return (404, [:], Data()) }
            return (400, HubFixture.jsonHeaders(), Data(#"{"error":"invalid_grant"}"#.utf8))
        }

        let store = MemoryOAuthStore(preloaded: [resource: MCPOAuthState(
            clientID: "c-1",
            accessToken: "at-old",
            refreshToken: "rt-dead",
            expiresAt: Date(timeIntervalSinceNow: -10),
            tokenEndpoint: URL(string: "https://\(host)/auth/oauth/token")
        )])
        let client = MCPOAuthClient(
            configuration: MCPOAuthConfiguration(redirectURI: URL(string: "laplace://oauth-callback")!),
            store: store,
            presenter: AutoApprovePresenter(),
            session: MockHTTP.makeSession()
        )

        // No usable token — caller proceeds unauthenticated and 401 restarts the flow.
        #expect(try await client.validAccessToken(resource: resource) == nil)
        let saved = try #require(store.all[resource])
        #expect(saved.accessToken == nil)
        #expect(saved.refreshToken == nil)
        #expect(saved.clientID == "c-1")
    }

    @Test("signOut drops tokens, keeps the registered client")
    func signOut() async throws {
        let resource = URL(string: "https://oauth-signout.test/mcp")!
        let store = MemoryOAuthStore(preloaded: [resource: MCPOAuthState(
            clientID: "c-1",
            accessToken: "at",
            refreshToken: "rt",
            expiresAt: Date(timeIntervalSinceNow: 3600)
        )])
        let client = MCPOAuthClient(
            configuration: MCPOAuthConfiguration(redirectURI: URL(string: "laplace://oauth-callback")!),
            store: store,
            presenter: AutoApprovePresenter(),
            session: MockHTTP.makeSession()
        )

        try await client.signOut(resource: resource)
        #expect(await client.isAuthorized(resource: resource) == false)
        let saved = try #require(store.all[resource])
        #expect(saved.accessToken == nil)
        #expect(saved.clientID == "c-1")
    }
}
