import Foundation

// MARK: - Auth Credential

/// How to authenticate with the Anthropic API.
///
/// > **Important:** OAuth tokens from Claude Pro/Max subscriptions are restricted to official
/// > Anthropic applications per the Consumer Terms of Service. The `.oauth` credential is provided
/// > for Teams/Enterprise accounts or applications with explicit Anthropic authorization.
/// > For most use cases, use `.apiKey` with an API key from console.anthropic.com.
public enum AuthCredential: Sendable {
    /// Direct API key from console.anthropic.com (pay-per-token). Recommended for third-party apps.
    case apiKey(String)
    /// OAuth tokens for Teams/Enterprise accounts or Anthropic-authorized applications.
    case oauth(OAuthTokenManager)
}

// MARK: - OAuth Tokens

/// Holds the mutable OAuth token state. The app (e.g., Fermata) is responsible
/// for persisting these to Keychain after sessions.
public struct OAuthTokens: Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scope: String = "user:inference user:profile"
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }
}

// MARK: - OAuth Token Manager

/// Actor that owns OAuth tokens and handles proactive/reactive refresh.
/// The app constructs this with tokens obtained from the OAuth login flow.
public actor OAuthTokenManager {
    private var tokens: OAuthTokens
    private let clientID: String
    private let tokenEndpoint: URL
    private let session: URLSession

    /// Proactive refresh margin — refresh if token expires within this window.
    private let refreshMargin: TimeInterval = 300 // 5 minutes

    /// In-flight refresh task. Coalesces concurrent refresh requests.
    private var refreshTask: Task<String, Error>?

    public init(
        tokens: OAuthTokens,
        clientID: String = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        tokenEndpoint: URL = URL(string: "https://platform.claude.com/v1/oauth/token")!,
        session: URLSession = .shared
    ) {
        self.tokens = tokens
        self.clientID = clientID
        self.tokenEndpoint = tokenEndpoint
        self.session = session
    }

    /// Returns a valid access token, proactively refreshing if near expiry.
    public func validAccessToken() async throws -> String {
        if tokens.expiresAt.timeIntervalSinceNow < refreshMargin {
            return try await performRefresh()
        }
        return tokens.accessToken
    }

    /// Force-refresh after a 401. Returns the new access token.
    public func forceRefresh() async throws -> String {
        return try await performRefresh()
    }

    /// Read-only snapshot of current tokens for app-side persistence.
    public func currentTokens() -> OAuthTokens {
        tokens
    }

    // MARK: - Private

    private func performRefresh() async throws -> String {
        // Coalesce concurrent refresh calls
        if let existing = refreshTask {
            return try await existing.value
        }

        let currentRefreshToken = tokens.refreshToken
        let currentScope = tokens.scope
        let endpoint = tokenEndpoint
        let client = clientID
        let urlSession = session

        let task = Task<String, Error> {
            let body = [
                "grant_type=refresh_token",
                "refresh_token=\(currentRefreshToken)",
                "client_id=\(client)",
                "scope=\(currentScope)",
            ].joined(separator: "&")

            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "content-type")
            request.httpBody = body.data(using: .utf8)

            let (data, response) = try await urlSession.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw OAuthError.invalidResponse
            }
            guard http.statusCode == 200 else {
                let message = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw OAuthError.refreshFailed(statusCode: http.statusCode, message: message)
            }

            let decoded = try JSONDecoder().decode(TokenRefreshResponse.self, from: data)
            return decoded.accessToken
        }

        refreshTask = task

        do {
            let newAccessToken = try await task.value
            refreshTask = nil
            // Update stored tokens
            tokens.accessToken = newAccessToken
            return newAccessToken
        } catch {
            refreshTask = nil
            throw error
        }
    }
}

// MARK: - Token Refresh Response

struct TokenRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

// MARK: - OAuth Errors

public enum OAuthError: Error, Sendable {
    case invalidResponse
    case refreshFailed(statusCode: Int, message: String)
}
