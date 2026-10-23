import CryptoKit
import Foundation

/// How requests to ElevenLabs are authorized.
public enum ElevenLabsAuth: Sendable, Equatable {
    /// An API key from elevenlabs.io › Developers › API Keys.
    case apiKey(String)
    /// An account signed in with “Sign in with ElevenLabs” (OAuth).
    case account(ElevenLabsAccount)
}

/// Tokens from “Sign in with ElevenLabs”.
public struct ElevenLabsToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    /// The granted scopes, space-separated.
    public var scope: String

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public var scopes: Set<String> { Set(scope.split(separator: " ").map(String.init)) }
}

public enum ElevenLabsOAuthError: LocalizedError, Sendable, Equatable {
    case cancelled
    case denied
    case invalidScope
    case invalidGrant
    case stateMismatch
    case timedOut
    case portsInUse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .denied: "Access wasn't allowed on the ElevenLabs page."
        case .invalidScope: "ElevenLabs refused the permissions HanLens asked for."
        case .invalidGrant: "The sign-in has expired — please sign in again."
        case .stateMismatch: "The sign-in response didn't match this request — please try again."
        case .timedOut: "Sign-in timed out — please try again."
        case .portsInUse: "HanLens couldn't receive the sign-in because its local ports are in use."
        case .server(let message): message
        }
    }
}

/// “Sign in with ElevenLabs”: the OAuth 2.0 authorization code flow with PKCE, as a public client (no secret).
///
/// ElevenLabs has no dynamic client registration. Instead the client ID is the URL of a public client metadata
/// document naming the app and its redirect URIs — `macos/oauth/elevenlabs-client.json` in this repository,
/// served by jsDelivr — so that file must stay where it is. The redirect goes to a local port (RFC 8252 §7.3),
/// where `LoopbackRedirectReceiver` picks it up.
public enum ElevenLabsOAuth {
    public static let clientID = "https://cdn.jsdelivr.net/gh/an6122003/chinese-ocr-translate@main/macos/oauth/elevenlabs-client.json"
    static let issuers: Set<String> = ["https://api.us.elevenlabs.io", "https://api.elevenlabs.io"]
    static let authorizationEndpoint = "https://elevenlabs.io/app/oauth/authorize"
    static let tokenEndpoint = URL(string: "https://api.us.elevenlabs.io/v1/oauth/token")!
    static let revocationEndpoint = URL(string: "https://api.us.elevenlabs.io/v1/oauth/revoke")!

    /// The loopback ports listed in the client metadata document, tried in order.
    public static let redirectPorts: [UInt16] = [43617, 43618, 43619]
    /// Third-party apps may only ask for the scopes in ElevenLabs' server metadata (an error page, not a redirect,
    /// answers anything else), so a sign-in can speak but not list the account's voices or credits.
    public static let scopes = ["text_to_speech"]

    public static func redirectURI(port: UInt16) -> String { "http://localhost:\(port)/callback" }

    /// One trip through the ElevenLabs page: a PKCE verifier (RFC 7636) and an anti-forgery state.
    public struct Attempt: Sendable {
        public let redirectURI: String
        public let scopes: [String]
        let verifier: String
        let state: String

        public init(port: UInt16, scopes: [String] = ElevenLabsOAuth.scopes) {
            self.init(redirectURI: ElevenLabsOAuth.redirectURI(port: port), scopes: scopes,
                      verifier: ElevenLabsOAuth.randomToken(bytes: 32), state: ElevenLabsOAuth.randomToken(bytes: 16))
        }

        init(redirectURI: String, scopes: [String], verifier: String, state: String) {
            self.redirectURI = redirectURI
            self.scopes = scopes
            self.verifier = verifier
            self.state = state
        }

        /// The ElevenLabs page to open in the browser.
        public var authorizationURL: URL {
            URL(string: authorizationEndpoint + "?" + formEncoded([
                ("response_type", "code"),
                ("client_id", clientID),
                ("redirect_uri", redirectURI),
                ("scope", scopes.joined(separator: " ")),
                ("state", state),
                ("code_challenge", codeChallenge(for: verifier)),
                ("code_challenge_method", "S256"),
            ]))!
        }
    }

    /// Reads the browser's redirect: the authorization code, or why there is none.
    public static func code(from callback: URL, for attempt: Attempt) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == attempt.state else { throw ElevenLabsOAuthError.stateMismatch }
        // RFC 9207: the response names the server that sent it.
        if let issuer = value("iss"), !issuers.contains(issuer) { throw ElevenLabsOAuthError.stateMismatch }
        if let error = value("error") {
            switch error {
            case "access_denied": throw ElevenLabsOAuthError.denied
            case "invalid_scope": throw ElevenLabsOAuthError.invalidScope
            default: throw ElevenLabsOAuthError.server(value("error_description") ?? error)
            }
        }
        guard let code = value("code"), !code.isEmpty else { throw ElevenLabsOAuthError.server("ElevenLabs sent no authorization code.") }
        return code
    }

    /// Trades the authorization code for tokens.
    public static func exchange(code: String, attempt: Attempt) async throws -> ElevenLabsToken {
        try await requestToken([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", attempt.redirectURI),
            ("client_id", clientID),
            ("code_verifier", attempt.verifier),
        ], previous: nil, requestedScope: attempt.scopes.joined(separator: " "))
    }

    /// New tokens from the refresh token; `invalidGrant` when it no longer works (revoked or expired).
    @Sendable public static func refresh(_ token: ElevenLabsToken) async throws -> ElevenLabsToken {
        guard let refreshToken = token.refreshToken else { throw ElevenLabsOAuthError.invalidGrant }
        return try await requestToken([
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ], previous: token, requestedScope: token.scope)
    }

    /// Ends the sign-in on the server too (best effort — the tokens are deleted locally either way).
    public static func revoke(_ token: ElevenLabsToken) async {
        var request = URLRequest(url: revocationEndpoint, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (value, hint) = token.refreshToken.map { ($0, "refresh_token") } ?? (token.accessToken, "access_token")
        request.httpBody = Data(formEncoded([("token", value), ("token_type_hint", hint), ("client_id", clientID)]).utf8)
        _ = try? await URLSession.shared.data(for: request)
    }

    private static func requestToken(_ form: [(String, String)], previous: ElevenLabsToken?,
                                     requestedScope: String) async throws -> ElevenLabsToken {
        var request = URLRequest(url: tokenEndpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncoded(form).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return try token(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                         previous: previous, requestedScope: requestedScope, now: Date())
    }

    /// Parses a token response (RFC 6749 §5; ElevenLabs wraps errors in "detail").
    static func token(from data: Data, status: Int, previous: ElevenLabsToken?, requestedScope: String,
                      now: Date) throws -> ElevenLabsToken {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status), let access = json["access_token"] as? String, !access.isEmpty else {
            let body = json["detail"] as? [String: Any] ?? json
            let error = body["error"] as? String
            if error == "invalid_grant" { throw ElevenLabsOAuthError.invalidGrant }
            throw ElevenLabsOAuthError.server(body["error_description"] as? String ?? body["message"] as? String
                                              ?? error ?? "ElevenLabs answered HTTP \(status).")
        }
        let lifetime = (json["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return ElevenLabsToken(accessToken: access,
                               // Keep the old refresh token unless the server rotated it.
                               refreshToken: json["refresh_token"] as? String ?? previous?.refreshToken,
                               expiresAt: now.addingTimeInterval(lifetime),
                               scope: json["scope"] as? String ?? previous?.scope ?? requestedScope)
    }

    // MARK: Helpers

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomToken(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL(Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formEncoded(_ pairs: [(String, String)]) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text }
        return pairs.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}

/// A signed-in ElevenLabs account. Hands out access tokens, refreshing them shortly before they expire — one
/// refresh at a time, since a refresh token may only work once — and reports new tokens so the app can store
/// them (nil: the sign-in ended and the user has to sign in again).
public actor ElevenLabsAccount {
    public typealias Refresher = @Sendable (ElevenLabsToken) async throws -> ElevenLabsToken

    public private(set) var token: ElevenLabsToken
    private let refresher: Refresher
    private let onChange: @Sendable (ElevenLabsToken?) -> Void
    private var refreshing: Task<Void, any Error>?
    private var hasEnded = false

    public init(token: ElevenLabsToken, refresher: @escaping Refresher = ElevenLabsOAuth.refresh,
                onChange: @escaping @Sendable (ElevenLabsToken?) -> Void) {
        self.token = token
        self.refresher = refresher
        self.onChange = onChange
    }

    /// A current access token. Pass the token the API just rejected to get a refreshed one.
    public func accessToken(rejected: String? = nil) async throws -> String {
        if let refreshing {
            try await refreshing.value
        } else if hasEnded {
            throw CloudVoiceError.signInExpired
        } else if token.expiresAt.timeIntervalSinceNow < 60 || rejected == token.accessToken {
            let task = Task { try await self.refresh() }
            refreshing = task
            defer { refreshing = nil }
            try await task.value
        }
        return token.accessToken
    }

    private func refresh() async throws {
        do {
            token = try await refresher(token)
            onChange(token)
        } catch ElevenLabsOAuthError.invalidGrant {
            hasEnded = true
            onChange(nil)
            throw CloudVoiceError.signInExpired
        }
    }
}

extension ElevenLabsAccount: Equatable {
    public static func == (lhs: ElevenLabsAccount, rhs: ElevenLabsAccount) -> Bool { lhs === rhs }
}
