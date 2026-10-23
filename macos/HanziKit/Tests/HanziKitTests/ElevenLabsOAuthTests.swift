import Foundation
import Synchronization
import Testing
@testable import HanziKit

@Suite("ElevenLabs sign-in")
struct ElevenLabsOAuthTests {
    private let attempt = ElevenLabsOAuth.Attempt(redirectURI: "http://localhost:43617/callback", scopes: ["text_to_speech", "voices_read"],
                                                  verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "s1")

    @Test func pkceMatchesTheRFCExample() {
        // RFC 7636, appendix B.
        #expect(ElevenLabsOAuth.codeChallenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = ElevenLabsOAuth.randomToken(bytes: 32)
        #expect(verifier.count == 43)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(ElevenLabsOAuth.randomToken(bytes: 32) != verifier)
    }

    @Test func authorizationURLCarriesEverything() throws {
        let url = attempt.authorizationURL
        #expect(url.absoluteString.hasPrefix("https://elevenlabs.io/app/oauth/authorize?"))
        #expect(url.absoluteString.contains("scope=text_to_speech%20voices_read"))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(query == [
            "response_type": "code",
            "client_id": ElevenLabsOAuth.clientID,
            "redirect_uri": "http://localhost:43617/callback",
            "scope": "text_to_speech voices_read",
            "state": "s1",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
        ])
    }

    @Test func clientMetadataDocumentMatchesTheApp() throws {
        // The document is published from the repository; its URL is the client ID.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("oauth/elevenlabs-client.json")
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(document["client_id"] as? String == ElevenLabsOAuth.clientID)
        #expect(ElevenLabsOAuth.clientID.hasSuffix("/macos/oauth/elevenlabs-client.json"))
        let redirects = Set(document["redirect_uris"] as? [String] ?? [])
        #expect(ElevenLabsOAuth.redirectPorts.allSatisfy { redirects.contains(ElevenLabsOAuth.redirectURI(port: $0)) })
        let scopes = Set((document["scope"] as? String ?? "").split(separator: " ").map(String.init))
        #expect(scopes.isSuperset(of: ElevenLabsOAuth.scopes))
        #expect(document["token_endpoint_auth_method"] as? String == "none")
    }

    @Test func redirectIsCheckedBeforeUse() throws {
        func callback(_ query: String) -> URL { URL(string: "http://localhost:43617/callback?\(query)")! }
        #expect(try ElevenLabsOAuth.code(from: callback("code=abc&state=s1&iss=https%3A%2F%2Fapi.us.elevenlabs.io"), for: attempt) == "abc")
        #expect(throws: ElevenLabsOAuthError.stateMismatch) { try ElevenLabsOAuth.code(from: callback("code=abc&state=other"), for: attempt) }
        #expect(throws: ElevenLabsOAuthError.stateMismatch) {
            try ElevenLabsOAuth.code(from: callback("code=abc&state=s1&iss=https%3A%2F%2Fevil.example"), for: attempt)
        }
        #expect(throws: ElevenLabsOAuthError.denied) { try ElevenLabsOAuth.code(from: callback("error=access_denied&state=s1"), for: attempt) }
        #expect(throws: ElevenLabsOAuthError.invalidScope) { try ElevenLabsOAuth.code(from: callback("error=invalid_scope&state=s1"), for: attempt) }
        #expect(throws: ElevenLabsOAuthError.server("Bad client")) {
            try ElevenLabsOAuth.code(from: callback("error=invalid_request&error_description=Bad%20client&state=s1"), for: attempt)
        }
    }

    @Test func tokenResponsesAreParsed() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = try ElevenLabsOAuth.token(
            from: Data(#"{"access_token":"a1","token_type":"Bearer","expires_in":3600,"refresh_token":"r1","scope":"text_to_speech"}"#.utf8),
            status: 200, previous: nil, requestedScope: "text_to_speech voices_read", now: now)
        #expect(fresh == ElevenLabsToken(accessToken: "a1", refreshToken: "r1", expiresAt: now.addingTimeInterval(3600), scope: "text_to_speech"))

        // A refresh that doesn't rotate the refresh token keeps the old one.
        let refreshed = try ElevenLabsOAuth.token(from: Data(#"{"access_token":"a2","expires_in":60}"#.utf8),
                                                  status: 200, previous: fresh, requestedScope: fresh.scope, now: now)
        #expect(refreshed.refreshToken == "r1")
        #expect(refreshed.scope == "text_to_speech")

        #expect(throws: ElevenLabsOAuthError.invalidGrant) {
            try ElevenLabsOAuth.token(from: Data(#"{"detail":{"error":"invalid_grant","error_description":"Invalid authorization code"}}"#.utf8),
                                      status: 400, previous: nil, requestedScope: "", now: now)
        }
        #expect(throws: ElevenLabsOAuthError.server("Unknown client")) {
            try ElevenLabsOAuth.token(from: Data(#"{"error":"invalid_client","error_description":"Unknown client"}"#.utf8),
                                      status: 401, previous: nil, requestedScope: "", now: now)
        }
    }

    @Test func missingPermissionsAreReported() {
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        let body = Data(#"{"detail":{"status":"missing_permissions","message":"Missing the permission voices_read."}}"#.utf8)
        #expect(throws: CloudVoiceError.missingPermission("Missing the permission voices_read.")) { try CloudVoiceError.check(response, body) }
    }

    // MARK: Account

    private func token(_ access: String, expiresIn: TimeInterval) -> ElevenLabsToken {
        ElevenLabsToken(accessToken: access, refreshToken: "r", expiresAt: Date().addingTimeInterval(expiresIn), scope: "text_to_speech")
    }

    @Test func concurrentRequestsShareOneRefresh() async throws {
        let refreshes = Mutex(0)
        let changes = Mutex<[String?]>([])
        let account = ElevenLabsAccount(token: token("old", expiresIn: 10)) { old in
            refreshes.withLock { $0 += 1 }
            try await Task.sleep(for: .milliseconds(50))
            return ElevenLabsToken(accessToken: "new", refreshToken: "r2", expiresAt: Date().addingTimeInterval(3600), scope: old.scope)
        } onChange: { token in
            changes.withLock { $0.append(token?.accessToken) }
        }
        async let a = account.accessToken()
        async let b = account.accessToken()
        async let c = account.accessToken()
        #expect(try await [a, b, c] == ["new", "new", "new"])
        #expect(refreshes.withLock { $0 } == 1)
        #expect(changes.withLock { $0 } == ["new"])
        #expect(await account.token.refreshToken == "r2")
    }

    @Test func aRejectedTokenIsRefreshedOnce() async throws {
        let refreshes = Mutex(0)
        let account = ElevenLabsAccount(token: token("first", expiresIn: 3600)) { old in
            let count = refreshes.withLock { $0 += 1; return $0 }
            return ElevenLabsToken(accessToken: "token\(count)", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), scope: old.scope)
        } onChange: { _ in }
        #expect(try await account.accessToken() == "first") // still valid: no refresh
        #expect(try await account.accessToken(rejected: "first") == "token1")
        #expect(try await account.accessToken(rejected: "first") == "token1") // already replaced
        #expect(refreshes.withLock { $0 } == 1)
    }

    @Test func aDeadRefreshTokenEndsTheSignIn() async throws {
        let refreshes = Mutex(0)
        let changes = Mutex<[String?]>([])
        let account = ElevenLabsAccount(token: token("old", expiresIn: -1)) { _ in
            refreshes.withLock { $0 += 1 }
            throw ElevenLabsOAuthError.invalidGrant
        } onChange: { token in
            changes.withLock { $0.append(token?.accessToken) }
        }
        await #expect(throws: CloudVoiceError.signInExpired) { try await account.accessToken() }
        await #expect(throws: CloudVoiceError.signInExpired) { try await account.accessToken() }
        #expect(refreshes.withLock { $0 } == 1)
        #expect(changes.withLock { $0 } == [nil])
    }

    // MARK: Loopback redirect

    @Test func loopbackReceiverCatchesTheRedirect() async throws {
        let receiver = try await LoopbackRedirectReceiver.start(ports: [49_317, 49_318, 49_319])
        defer { receiver.close() }
        for host in ["127.0.0.1", "[::1]", "localhost"] {
            async let callback = receiver.nextCallback(timeout: 10)
            async let page = URLSession.shared.data(from: URL(string: "http://\(host):\(receiver.port)/callback?code=abc&state=xyz")!)
            let url = try await callback
            #expect(url.absoluteString == "http://localhost:\(receiver.port)/callback?code=abc&state=xyz")
            receiver.respond(title: "Signed in to ElevenLabs", message: "You can close this tab & go back.")
            let (data, response) = try await page
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let html = String(decoding: data, as: UTF8.self)
            #expect(html.contains("Signed in to ElevenLabs"))
            #expect(html.contains("close this tab &amp; go back"))
        }
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(receiver.port)/favicon.ico")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func loopbackReceiverSkipsBusyPortsAndStaysLocal() async throws {
        let first = try await LoopbackRedirectReceiver.start(ports: [49_327, 49_328])
        defer { first.close() }
        let second = try await LoopbackRedirectReceiver.start(ports: [49_327, 49_328])
        defer { second.close() }
        #expect(first.port == 49_327)
        #expect(second.port == 49_328)
        await #expect(throws: ElevenLabsOAuthError.portsInUse) {
            _ = try await LoopbackRedirectReceiver.start(ports: [49_327, 49_328])
        }
        // Not reachable through the Mac's network address.
        if let address = Self.networkAddress() {
            var request = URLRequest(url: URL(string: "http://\(address):\(first.port)/callback?code=x&state=y")!)
            request.timeoutInterval = 3
            await #expect(throws: (any Error).self) { _ = try await URLSession.shared.data(for: request) }
        }
    }

    @Test func closingEndsTheWait() async throws {
        let receiver = try await LoopbackRedirectReceiver.start(ports: [49_337, 49_338])
        let waiter = Task { try await receiver.nextCallback(timeout: 10) }
        try await Task.sleep(for: .milliseconds(100))
        receiver.close()
        await #expect(throws: ElevenLabsOAuthError.cancelled) { _ = try await waiter.value }
    }

    /// This Mac's first non-loopback IPv4 address, if it has one.
    private static func networkAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (Int32(entry.pointee.ifa_flags) & IFF_LOOPBACK) == 0, (Int32(entry.pointee.ifa_flags) & IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return nil
    }
}
