import Foundation

public struct VoiceCloneAccount: Equatable, Sendable {
    public let id: String
    public let email: String?
    public let isEmailVerified: Bool
    public let usesApple: Bool
    public let usesPassword: Bool

    public init(id: String, email: String?, isEmailVerified: Bool, usesApple: Bool, usesPassword: Bool) {
        self.id = id
        self.email = email
        self.isEmailVerified = isEmailVerified
        self.usesApple = usesApple
        self.usesPassword = usesPassword
    }
}

@MainActor
public protocol AccountAuthenticating {
    var currentAccount: VoiceCloneAccount? { get }
    func accountChanges() -> AsyncStream<VoiceCloneAccount?>
    func signIn(email: String, password: String) async throws
    func createAccount(email: String, password: String) async throws
    func signInWithApple(identityToken: String, nonce: String, givenName: String?, familyName: String?) async throws
    func linkApple(identityToken: String, nonce: String, givenName: String?, familyName: String?) async throws
    func linkPassword(email: String, password: String) async throws
    func sendPasswordReset(email: String) async throws
    func sendVerification() async throws
    func refreshAccount() async throws
    func reauthenticate(password: String) async throws
    func reauthenticateWithApple(identityToken: String, nonce: String) async throws
    func deleteAccount(appleAuthorizationCode: String?) async throws
    func signOut() throws
}

public enum AccountError: LocalizedError {
    case unavailable, signedOut, appleAuthorizationRequired

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Sign-in is not configured for this build."
        case .signedOut: "Sign in again to continue."
        case .appleAuthorizationRequired: "Confirm your Apple account to delete your VoiceClone account."
        }
    }
}
