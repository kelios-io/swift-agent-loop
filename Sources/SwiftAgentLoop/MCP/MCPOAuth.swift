import CryptoKit
import Foundation

// MARK: - Configuration

/// Static configuration for authorizing against one MCP server's OAuth
/// authorization server (spec: MCP Authorization, OAuth 2.1 subset).
public struct MCPOAuthConfiguration: Sendable {
    /// `client_name` sent during dynamic client registration.
    public var clientName: String
    /// Where the authorization server redirects after login. Must be a URL the
    /// app can intercept (custom scheme, e.g. `laplace://oauth-callback`).
    public var redirectURI: URL
    /// Scopes to request. `nil` requests the server's advertised
    /// `scopes_supported`; if the server advertises none, the parameter is omitted.
    public var scopes: [String]?

    public init(clientName: String = "swift-agent-loop", redirectURI: URL, scopes: [String]? = nil) {
        self.clientName = clientName
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

// MARK: - Persisted state

/// Everything worth persisting between launches, per server: the dynamically
/// registered client and the current tokens. The app decides where this lives
/// (Keychain, file, memory) via `MCPOAuthStateStore`.
public struct MCPOAuthState: Codable, Sendable, Equatable {
    public var clientID: String?
    public var accessToken: String?
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?
    public var tokenEndpoint: URL?

    public init(
        clientID: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        scope: String? = nil,
        tokenEndpoint: URL? = nil
    ) {
        self.clientID = clientID
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenEndpoint = tokenEndpoint
    }
}

/// App-provided persistence for `MCPOAuthState`, keyed by server URL.
public protocol MCPOAuthStateStore: Sendable {
    func load(server: URL) async throws -> MCPOAuthState?
    func save(_ state: MCPOAuthState, server: URL) async throws
}

// MARK: - Presenter

/// App-provided UI hook: present the authorization page to the user (typically
/// `ASWebAuthenticationSession` on Apple platforms) and return the full
/// redirect URL the browser was sent to. Throw to abort (user cancelled).
public protocol MCPOAuthPresenter: Sendable {
    func present(authorizationURL: URL, redirectURI: URL) async throws -> URL
}

// MARK: - Errors

public enum MCPOAuthError: Error, Sendable {
    case discoveryFailed(String)
    case registrationNotSupported
    case registrationFailed(status: Int, body: String)
    case authorizationDenied(String)
    case stateMismatch
    case missingAuthorizationCode
    case tokenExchangeFailed(status: Int, body: String)
    case refreshFailed(status: Int, body: String)
    case notAuthorized
}

// MARK: - MCPOAuthClient

/// Owns the OAuth lifecycle for one MCP server: metadata discovery, dynamic
/// client registration, PKCE authorization-code flow (browser presented by the
/// app), token exchange, and refresh. `MCPHTTPClient` consults it for a token
/// on every request and triggers `authorize` on a 401.
public actor MCPOAuthClient {
    private let configuration: MCPOAuthConfiguration
    private let store: any MCPOAuthStateStore
    private let presenter: any MCPOAuthPresenter
    private let session: URLSession

    private var state: MCPOAuthState?
    private var loadedFromStore = false
    /// Coalesces concurrent authorize calls into one browser flow.
    private var authorizeTask: Task<String, Error>?
    /// Coalesces concurrent refresh calls.
    private var refreshTask: Task<String, Error>?
    /// Refresh proactively when the token expires within this window.
    private let refreshMargin: TimeInterval = 60

    public init(
        configuration: MCPOAuthConfiguration,
        store: any MCPOAuthStateStore,
        presenter: any MCPOAuthPresenter,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.store = store
        self.presenter = presenter
        self.session = session
    }

    // MARK: Public surface

    /// The current access token, refreshed proactively when near expiry.
    /// Returns nil when there is no usable token (never authorized, or refresh
    /// failed) — the caller should proceed unauthenticated and run `authorize`
    /// on the resulting 401.
    public func validAccessToken(resource: URL) async throws -> String? {
        try await loadIfNeeded(resource)
        guard let current = state, let token = current.accessToken else { return nil }
        guard let expiresAt = current.expiresAt, expiresAt.timeIntervalSinceNow < refreshMargin else {
            return token
        }
        guard current.refreshToken != nil else { return nil }
        do {
            return try await refresh(resource: resource)
        } catch {
            // Cleared by refresh(); fall back to the full flow via 401.
            return nil
        }
    }

    /// True when a token is stored (it may still be rejected server-side).
    public func isAuthorized(resource: URL) async -> Bool {
        try? await loadIfNeeded(resource)
        return state?.accessToken != nil
    }

    /// Run the full authorization flow: discovery → (registration) → PKCE
    /// browser flow → token exchange. Safe to call directly (a Settings
    /// "Sign in" button) or from a 401. Concurrent calls share one flow.
    public func authorize(resource: URL, wwwAuthenticate: String? = nil) async throws -> String {
        if let existing = authorizeTask { return try await existing.value }
        let task = Task<String, Error> {
            try await performAuthorize(resource: resource, wwwAuthenticate: wwwAuthenticate)
        }
        authorizeTask = task
        defer { authorizeTask = nil }
        return try await task.value
    }

    /// Drop tokens (keeps the registered client so re-auth skips registration).
    public func signOut(resource: URL) async throws {
        try await loadIfNeeded(resource)
        var next = state ?? MCPOAuthState()
        next.accessToken = nil
        next.refreshToken = nil
        next.expiresAt = nil
        next.scope = nil
        state = next
        try await store.save(next, server: resource)
    }

    // MARK: Flow

    private func performAuthorize(resource: URL, wwwAuthenticate: String?) async throws -> String {
        try await loadIfNeeded(resource)

        let resourceMetadata = try await discoverProtectedResource(resource: resource, wwwAuthenticate: wwwAuthenticate)
        let authServer = resourceMetadata?.authorizationServers?.first ?? origin(of: resource)
        let metadata = try await discoverAuthorizationServer(authServer)

        var current = state ?? MCPOAuthState()
        let clientID: String
        if let existing = current.clientID {
            clientID = existing
        } else {
            clientID = try await register(with: metadata)
            current.clientID = clientID
            state = current
            try await store.save(current, server: resource)
        }

        let verifier = PKCE.generateVerifier()
        let stateParam = PKCE.randomURLSafeString(bytes: 16)
        let authorizationURL = try buildAuthorizationURL(
            metadata: metadata,
            clientID: clientID,
            resource: resource,
            codeChallenge: PKCE.challenge(for: verifier),
            state: stateParam
        )

        let redirect = try await presenter.present(
            authorizationURL: authorizationURL,
            redirectURI: configuration.redirectURI
        )
        let code = try parseRedirect(redirect, expectedState: stateParam)

        let tokens = try await exchange(
            code: code,
            verifier: verifier,
            clientID: clientID,
            tokenEndpoint: metadata.tokenEndpoint,
            resource: resource
        )
        current.accessToken = tokens.accessToken
        current.refreshToken = tokens.refreshToken
        current.expiresAt = tokens.expiresIn.map { Date(timeIntervalSinceNow: TimeInterval($0)) }
        current.scope = tokens.scope
        current.tokenEndpoint = metadata.tokenEndpoint
        state = current
        try await store.save(current, server: resource)
        return tokens.accessToken
    }

    private func refresh(resource: URL) async throws -> String {
        if let existing = refreshTask { return try await existing.value }
        let task = Task<String, Error> { try await performRefresh(resource: resource) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(resource: URL) async throws -> String {
        guard let current = state,
              let refreshToken = current.refreshToken,
              let clientID = current.clientID,
              let tokenEndpoint = current.tokenEndpoint else {
            throw MCPOAuthError.notAuthorized
        }

        let request = Self.formRequest(url: tokenEndpoint, fields: [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
            ("resource", resource.absoluteString),
        ])
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                throw MCPOAuthError.refreshFailed(status: status, body: String(data: data, encoding: .utf8) ?? "")
            }
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            var next = current
            next.accessToken = decoded.accessToken
            // Rotation: keep the old refresh token unless the server issued a new one.
            next.refreshToken = decoded.refreshToken ?? refreshToken
            next.expiresAt = decoded.expiresIn.map { Date(timeIntervalSinceNow: TimeInterval($0)) }
            next.scope = decoded.scope ?? current.scope
            state = next
            try await store.save(next, server: resource)
            return decoded.accessToken
        } catch {
            // Only a definitive 4xx means the refresh token is dead; clearing on
            // a network blip would force a needless re-login.
            if case MCPOAuthError.refreshFailed(let status, _) = error, (400...499).contains(status) {
                var next = current
                next.accessToken = nil
                next.refreshToken = nil
                next.expiresAt = nil
                state = next
                try? await store.save(next, server: resource)
            }
            throw error
        }
    }

    // MARK: Discovery

    private func loadIfNeeded(_ resource: URL) async throws {
        guard !loadedFromStore else { return }
        loadedFromStore = true
        state = try await store.load(server: resource)
    }

    private func discoverProtectedResource(resource: URL, wwwAuthenticate: String?) async throws -> ProtectedResourceMetadata? {
        var candidates: [URL] = []
        if let header = wwwAuthenticate, let advertised = Self.resourceMetadataURL(fromWWWAuthenticate: header) {
            candidates.append(advertised)
        }
        candidates.append(contentsOf: wellKnownCandidates(base: resource, suffix: "oauth-protected-resource"))
        for url in candidates {
            if let metadata: ProtectedResourceMetadata = try? await getJSON(url) { return metadata }
        }
        return nil // legacy servers: fall back to the resource origin as the AS
    }

    private func discoverAuthorizationServer(_ server: URL) async throws -> AuthorizationServerMetadata {
        var candidates = wellKnownCandidates(base: server, suffix: "oauth-authorization-server")
        candidates.append(contentsOf: wellKnownCandidates(base: server, suffix: "openid-configuration"))
        for url in candidates {
            if let metadata: AuthorizationServerMetadata = try? await getJSON(url) { return metadata }
        }
        throw MCPOAuthError.discoveryFailed("no authorization server metadata at \(server.absoluteString)")
    }

    /// RFC 8414/9728 well-known locations: with the base URL's path inserted
    /// after the well-known segment, and at the bare origin.
    private func wellKnownCandidates(base: URL, suffix: String) -> [URL] {
        let origin = origin(of: base)
        let path = base.path
        var candidates: [URL] = []
        if !path.isEmpty, path != "/" {
            candidates.append(origin.appendingPathComponent(".well-known/\(suffix)\(path)"))
        }
        candidates.append(origin.appendingPathComponent(".well-known/\(suffix)"))
        return candidates
    }

    private func origin(of url: URL) -> URL {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.url ?? url
    }

    private func getJSON<T: Decodable>(_ url: URL) async throws -> T? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Extract `resource_metadata="…"` from a `WWW-Authenticate` header.
    static func resourceMetadataURL(fromWWWAuthenticate header: String) -> URL? {
        guard let range = header.range(of: "resource_metadata=\"") else { return nil }
        let rest = header[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return URL(string: String(rest[..<end]))
    }

    // MARK: Registration & exchange

    private func register(with metadata: AuthorizationServerMetadata) async throws -> String {
        guard let endpoint = metadata.registrationEndpoint else {
            throw MCPOAuthError.registrationNotSupported
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ClientRegistrationRequest(
            clientName: configuration.clientName,
            redirectUris: [configuration.redirectURI.absoluteString]
        ))
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw MCPOAuthError.registrationFailed(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(ClientRegistrationResponse.self, from: data).clientID
    }

    private func buildAuthorizationURL(
        metadata: AuthorizationServerMetadata,
        clientID: String,
        resource: URL,
        codeChallenge: String,
        state: String
    ) throws -> URL {
        guard var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw MCPOAuthError.discoveryFailed("unusable authorization_endpoint")
        }
        var items = components.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resource.absoluteString),
        ])
        let scopes = configuration.scopes ?? metadata.scopesSupported
        if let scopes, !scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        components.queryItems = items
        guard let url = components.url else {
            throw MCPOAuthError.discoveryFailed("unusable authorization_endpoint")
        }
        return url
    }

    private func parseRedirect(_ redirect: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw MCPOAuthError.authorizationDenied(value("error_description") ?? error)
        }
        guard value("state") == expectedState else { throw MCPOAuthError.stateMismatch }
        guard let code = value("code") else { throw MCPOAuthError.missingAuthorizationCode }
        return code
    }

    private func exchange(
        code: String,
        verifier: String,
        clientID: String,
        tokenEndpoint: URL,
        resource: URL
    ) async throws -> TokenResponse {
        let request = Self.formRequest(url: tokenEndpoint, fields: [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", configuration.redirectURI.absoluteString),
            ("client_id", clientID),
            ("code_verifier", verifier),
            ("resource", resource.absoluteString),
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw MCPOAuthError.tokenExchangeFailed(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    static func formRequest(url: URL, fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = fields
            .map { "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: .formValueAllowed) ?? $0.1)" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }
}

// MARK: - PKCE

enum PKCE {
    /// RFC 7636 code verifier: 32 random bytes, base64url → 43 chars.
    static func generateVerifier() -> String {
        randomURLSafeString(bytes: 32)
    }

    /// S256 challenge: base64url(SHA-256(ascii(verifier))).
    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    static func randomURLSafeString(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension CharacterSet {
    /// Characters that need no escaping in a form-urlencoded value.
    static let formValueAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}

// MARK: - Metadata & token wire types

struct ProtectedResourceMetadata: Decodable {
    let authorizationServers: [URL]?

    private enum CodingKeys: String, CodingKey {
        case authorizationServers = "authorization_servers"
    }
}

struct AuthorizationServerMetadata: Decodable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?
    let scopesSupported: [String]?

    private enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
    }
}

struct ClientRegistrationRequest: Encodable {
    let clientName: String
    let redirectUris: [String]
    let grantTypes = ["authorization_code", "refresh_token"]
    let responseTypes = ["code"]
    let tokenEndpointAuthMethod = "none"

    private enum CodingKeys: String, CodingKey {
        case clientName = "client_name"
        case redirectUris = "redirect_uris"
        case grantTypes = "grant_types"
        case responseTypes = "response_types"
        case tokenEndpointAuthMethod = "token_endpoint_auth_method"
    }
}

struct ClientRegistrationResponse: Decodable {
    let clientID: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?
    let scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope = "scope"
    }
}
