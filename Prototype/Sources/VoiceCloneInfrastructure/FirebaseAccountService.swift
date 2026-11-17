import FirebaseAuth
import FirebaseCore
import Foundation
import VoiceCloneCore

@MainActor
public final class FirebaseAccountService: AccountAuthenticating {
    private let auth: Auth

    public init?(configuration: URL?, useLocalEmulator: Bool = false) {
        guard let configuration, let options = FirebaseOptions(contentsOfFile: configuration.path),
              options.bundleID == Bundle.main.bundleIdentifier else { return nil }
        if useLocalEmulator {
            options.projectID = "demo-voiceclone"
            let name = "VoiceCloneAuthEmulator"
            if FirebaseApp.app(name: name) == nil { FirebaseApp.configure(name: name, options: options) }
            guard let app = FirebaseApp.app(name: name) else { return nil }
            auth = Auth.auth(app: app)
            auth.useEmulator(withHost: "127.0.0.1", port: 9099)
        } else {
            if FirebaseApp.app() == nil { FirebaseApp.configure(options: options) }
            auth = Auth.auth()
        }
    }

    public var currentAccount: VoiceCloneAccount? { auth.currentUser.map(Self.account) }

    public func accountChanges() -> AsyncStream<VoiceCloneAccount?> {
        AsyncStream { continuation in
            let listener = auth.addStateDidChangeListener { _, user in
                continuation.yield(user.map(Self.account))
            }
            continuation.onTermination = { [auth] _ in auth.removeStateDidChangeListener(listener) }
        }
    }

    public func signIn(email: String, password: String) async throws {
        _ = try await auth.signIn(withEmail: email, password: password)
    }

    public func createAccount(email: String, password: String) async throws {
        _ = try await auth.createUser(withEmail: email, password: password)
    }

    public func signInWithApple(identityToken: String, nonce: String, givenName: String?, familyName: String?) async throws {
        let credential = appleCredential(identityToken: identityToken, nonce: nonce, givenName: givenName, familyName: familyName)
        _ = try await auth.signIn(with: credential)
    }

    public func linkApple(identityToken: String, nonce: String, givenName: String?, familyName: String?) async throws {
        let credential = appleCredential(identityToken: identityToken, nonce: nonce, givenName: givenName, familyName: familyName)
        _ = try await requireUser().link(with: credential)
    }

    public func linkPassword(email: String, password: String) async throws {
        _ = try await requireUser().link(with: EmailAuthProvider.credential(withEmail: email, password: password))
    }

    public func sendPasswordReset(email: String) async throws {
        try await auth.sendPasswordReset(withEmail: email)
    }

    public func sendVerification() async throws {
        try await requireUser().sendEmailVerification()
    }

    public func refreshAccount() async throws {
        try await requireUser().reload()
    }

    public func reauthenticate(password: String) async throws {
        let user = try requireUser()
        guard let email = user.email else { throw AccountError.signedOut }
        _ = try await user.reauthenticate(with: EmailAuthProvider.credential(withEmail: email, password: password))
    }

    public func reauthenticateWithApple(identityToken: String, nonce: String) async throws {
        _ = try await requireUser().reauthenticate(with: appleCredential(identityToken: identityToken, nonce: nonce))
    }

    public func deleteAccount(appleAuthorizationCode: String?) async throws {
        let user = try requireUser()
        if user.providerData.contains(where: { $0.providerID == "apple.com" }) {
            guard let appleAuthorizationCode else { throw AccountError.appleAuthorizationRequired }
            try await auth.revokeToken(withAuthorizationCode: appleAuthorizationCode)
        }
        try await user.delete()
    }

    public func signOut() throws {
        try auth.signOut()
    }

    private func requireUser() throws -> User {
        guard let user = auth.currentUser else { throw AccountError.signedOut }
        return user
    }

    private func appleCredential(identityToken: String, nonce: String, givenName: String? = nil, familyName: String? = nil) -> OAuthCredential {
        var name = PersonNameComponents()
        name.givenName = givenName
        name.familyName = familyName
        return OAuthProvider.appleCredential(withIDToken: identityToken, rawNonce: nonce, fullName: name)
    }

    nonisolated private static func account(_ user: User) -> VoiceCloneAccount {
        VoiceCloneAccount(id: user.uid, email: user.email, isEmailVerified: user.isEmailVerified,
                          usesApple: user.providerData.contains { $0.providerID == "apple.com" },
                          usesPassword: user.providerData.contains { $0.providerID == "password" })
    }
}
