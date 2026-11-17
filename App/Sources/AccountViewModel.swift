import Foundation
import Observation
import VoiceCloneCore

@MainActor
@Observable
final class AccountViewModel {
    private let service: (any AccountAuthenticating)?
    private let removeLocalData: (String) throws -> Void
    private(set) var account: VoiceCloneAccount?
    private(set) var isBusy = false
    var email = ""
    var password = ""
    var message: String?
    var error: String?

    init(service: (any AccountAuthenticating)?, removeLocalData: @escaping (String) throws -> Void) {
        self.service = service
        self.removeLocalData = removeLocalData
    }

    var isConfigured: Bool { service != nil }

    func update(_ account: VoiceCloneAccount?) {
        if self.account?.id != account?.id {
            password = ""
            email = account?.email ?? ""
            message = nil
            error = nil
        }
        self.account = account
    }

    func signIn(create: Bool) async {
        await perform { service in
            if create {
                try await service.createAccount(email: self.normalizedEmail, password: self.password)
                do {
                    try await service.sendVerification()
                    self.message = "Account created. Check your inbox to verify your email."
                } catch {
                    self.message = "Account created. You can resend the verification email from Account."
                }
            } else {
                try await service.signIn(email: self.normalizedEmail, password: self.password)
            }
            self.password = ""
        }
    }

    func resetPassword() async {
        await perform { service in
            try await service.sendPasswordReset(email: self.normalizedEmail)
            self.message = "If an account exists for this email, you will receive password reset instructions."
        }
    }

    func verifyEmail() async {
        await perform { service in
            try await service.sendVerification()
            self.message = "Verification email sent. Check your inbox."
        }
    }

    func refresh() async {
        await perform { service in
            try await service.refreshAccount()
            self.update(service.currentAccount)
        }
    }

    func linkPassword() async {
        await perform { service in
            try await service.linkPassword(email: self.normalizedEmail, password: self.password)
            self.update(service.currentAccount)
            self.password = ""
            self.message = "Email and password linked to this account."
        }
    }

    func signOut() async {
        await perform { service in try service.signOut() }
    }

    func useApple(_ credential: AppleAccountCredential, action: AppleAccountAction) async {
        await perform { service in
            switch action {
            case .signIn:
                try await service.signInWithApple(identityToken: credential.identityToken, nonce: credential.nonce,
                                                  givenName: credential.givenName, familyName: credential.familyName)
            case .link:
                try await service.linkApple(identityToken: credential.identityToken, nonce: credential.nonce,
                                            givenName: credential.givenName, familyName: credential.familyName)
                self.update(service.currentAccount)
                self.message = "Apple linked to this account."
            case .delete:
                try await service.reauthenticateWithApple(identityToken: credential.identityToken, nonce: credential.nonce)
                try await self.delete(using: service, appleAuthorizationCode: credential.authorizationCode)
            }
        }
    }

    func deleteWithPassword() async {
        await perform { service in
            try await service.reauthenticate(password: self.password)
            try await self.delete(using: service, appleAuthorizationCode: nil)
        }
    }

    private var normalizedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func delete(using service: any AccountAuthenticating, appleAuthorizationCode: String?) async throws {
        guard let id = account?.id else { throw AccountError.signedOut }
        try await service.deleteAccount(appleAuthorizationCode: appleAuthorizationCode)
        password = ""
        do { try removeLocalData(id) }
        catch {
            self.error = "Your account was deleted, but its local files could not be removed. \(error.localizedDescription)"
        }
    }

    private func perform(_ operation: (any AccountAuthenticating) async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        message = nil
        defer { isBusy = false }
        do {
            guard let service else { throw AccountError.unavailable }
            try await operation(service)
        } catch { self.error = error.localizedDescription }
    }
}
