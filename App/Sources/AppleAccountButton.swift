import AuthenticationServices
import CryptoKit
import Security
import SwiftUI

struct AppleAccountCredential {
    let identityToken: String
    let authorizationCode: String
    let nonce: String
    let givenName: String?
    let familyName: String?
}

enum AppleAccountAction {
    case signIn, link, delete
}

struct AppleAccountButton: View {
    let action: (AppleAccountCredential) async -> Void
    let reportError: (String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var nonce: String?

    var body: some View {
        SignInWithAppleButton(.continue) { request in
            // Generate a fresh cryptographic nonce for every authorization attempt.
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                nonce = nil
                reportError("Could not securely start Apple sign-in. Try again.")
                return
            }
            let value = bytes.map { String(format: "%02x", $0) }.joined()
            nonce = value
            request.nonce = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            request.requestedScopes = [.email, .fullName]
        } onCompletion: { result in
            defer { nonce = nil }
            switch result {
            case .success(let authorization):
                guard let nonce, let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                      let identityData = credential.identityToken, let identity = String(data: identityData, encoding: .utf8),
                      let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8) else {
                    reportError("Apple did not return the credentials needed to continue. Try again.")
                    return
                }
                let value = AppleAccountCredential(identityToken: identity, authorizationCode: code, nonce: nonce,
                                                   givenName: credential.fullName?.givenName, familyName: credential.fullName?.familyName)
                Task { await action(value) }
            case .failure(let error):
                guard (error as? ASAuthorizationError)?.code != .canceled else { return }
                reportError(error.localizedDescription)
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 44)
    }
}
