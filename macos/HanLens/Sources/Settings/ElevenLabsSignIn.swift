import AppKit
import HanziKit
import Observation

/// “Sign in with ElevenLabs”: opens the ElevenLabs page in the default browser, where the user is usually
/// signed in already, and waits for it to send the browser back to HanLens on a local port.
@Observable
final class ElevenLabsSignIn {
    static let shared = ElevenLabsSignIn()

    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Signs in and stores the account in `settings`. `completion` gets nil on success, or the error to show
    /// (it isn't called when the sign-in is cancelled).
    func start(settings: AppSettings, completion: @escaping (String?) -> Void) {
        guard !isRunning else { return }
        isRunning = true
        task = Task {
            defer {
                isRunning = false
                task = nil
            }
            do {
                let token = try await Self.signIn()
                settings.signInToElevenLabs(with: token)
                AppController.shared.showSettings(tab: .speech) // Back from the browser.
                completion(nil)
            } catch ElevenLabsOAuthError.cancelled {
            } catch is CancellationError {
            } catch {
                Log.app.error("ElevenLabs sign-in failed: \(error.localizedDescription, privacy: .public)")
                completion(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private static func signIn() async throws -> ElevenLabsToken {
        let receiver = try await LoopbackRedirectReceiver.start(ports: ElevenLabsOAuth.redirectPorts)
        defer { receiver.close() }
        let attempt = ElevenLabsOAuth.Attempt(port: receiver.port)
        NSWorkspace.shared.open(attempt.authorizationURL)
        let callback = try await receiver.nextCallback()
        do {
            let code = try ElevenLabsOAuth.code(from: callback, for: attempt)
            let token = try await ElevenLabsOAuth.exchange(code: code, attempt: attempt)
            receiver.respond(title: "Signed in to ElevenLabs", message: "You can close this tab and go back to HanLens.")
            Log.app.info("Signed in to ElevenLabs; scopes: \(token.scope, privacy: .public)")
            return token
        } catch {
            receiver.respond(title: "Sign-in didn't finish", message: error.localizedDescription)
            throw error
        }
    }
}
