import SwiftUI

struct AccountView: View {
    @Bindable var model: AccountViewModel
    var synchronization: CloudSyncViewModel? = nil
    var cloudNotice: String? = nil
    var requestCloudConsent: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var creatingAccount = false
    @State private var deletingAccount = false
    @State private var linkingApple = false
    @State private var confirmingDeletion = false

    var body: some View {
        NavigationStack {
            Form {
                if !model.isConfigured {
                    Section {
                        Text("Sign-in is not configured for this build.")
                        Text("Your projects and voices are available on this device.").foregroundStyle(.secondary)
                    }
                } else if let account = model.account {
                    Section("Signed in") {
                        if let email = account.email { Text(email).textSelection(.enabled) }

                    }
                    if let synchronization {
                        Section("iCloud sync") {
                            Toggle("Sync library", isOn: Binding(
                                get: { synchronization.preferences.isEnabled },
                                set: { enabled in
                                    if enabled && !synchronization.preferences.hasAskedConsent { requestCloudConsent() }
                                    else { Task { await synchronization.setEnabled(enabled) } }
                                }))
                            Toggle("Allow cellular audio transfers", isOn: Binding(
                                get: { synchronization.preferences.allowsCellularAudio },
                                set: { value in Task { await synchronization.setCellularAudio(value) } }))
                            Text("Reference recordings, scripts, projects, settings, and generated audio use your private iCloud storage. Use the same VoiceClone and iCloud accounts on your devices.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text(synchronization.status).font(.callout)
                            if let error = synchronization.error { Text(error).foregroundStyle(.red) }
                            if let date = synchronization.lastSynced {
                                LabeledContent("Last synced") { Text(date, style: .relative) }
                            }
                            Button("Sync now", action: synchronization.requestSync)
                                .disabled(!synchronization.preferences.isEnabled || synchronization.isSyncing)
                        }
                    } else if let cloudNotice {
                        Section("iCloud sync") { Text(cloudNotice) }
                    }
                    if account.usesPassword && !account.isEmailVerified {
                        Section("Verify your email") {
                            Button("Send verification email") { Task { await model.verifyEmail() } }
                            Button("I have verified my email") { Task { await model.refresh() } }
                        }
                    }
                    if !account.usesPassword {
                        Section {
                            emailField
                            passwordField(creating: true)
                            Text("Linking lets both sign-in methods access this VoiceClone account.").font(.footnote)
                            Button("Link email and password") { Task { await model.linkPassword() } }
                                .disabled(model.email.isEmpty || model.password.isEmpty)
                        } header: { Text("Email and password") }
                    }
                    if !account.usesApple {
                        Section {
                            Text("Linking lets Apple and your current sign-in method access this VoiceClone account.")
                                .font(.footnote)
                            if linkingApple {
                                appleButton(.link)
                            } else {
                                Button("Link Apple account") { linkingApple = true }
                            }
                        } header: { Text("Apple") }
                    }
                    Section {
                        Button("Sign out") { Task { await model.signOut() } }
                        Button("Delete account", role: .destructive) { deletingAccount = true }
                    }
                    if deletingAccount {
                        Section("Delete your account") {
                            Text("This permanently deletes your VoiceClone account, its local projects, voices, and audio. Cloud copies are removed when the original iCloud account is available.")
                            if account.usesApple {
                                Text("Confirm deletion, then continue with Apple to verify your identity.").font(.footnote)
                                if confirmingDeletion {
                                    appleButton(.delete)
                                } else {
                                    Button("Confirm account deletion", role: .destructive) { confirmingDeletion = true }
                                }
                            } else {
                                passwordField(creating: false)
                                Button("Permanently delete account", role: .destructive) { confirmingDeletion = true }
                                    .disabled(model.password.isEmpty)
                            }
                            Button("Cancel", role: .cancel) {
                                deletingAccount = false
                                confirmingDeletion = false
                                model.password = ""
                            }
                        }
                    }
                } else {
                    Section {
                        appleButton(.signIn)
                    }
                    Section(creatingAccount ? "Create an account" : "Sign in with email") {
                        emailField
                        passwordField(creating: creatingAccount)
                        Button(creatingAccount ? "Create account" : "Sign in") {
                            Task { await model.signIn(create: creatingAccount) }
                        }
                        .disabled(model.email.isEmpty || model.password.isEmpty)
                        Button(creatingAccount ? "Already have an account? Sign in" : "Create an account") {
                            creatingAccount.toggle()
                            model.password = ""
                            model.message = nil
                            model.error = nil
                        }
                        if !creatingAccount {
                            Button("Reset password") { Task { await model.resetPassword() } }
                                .disabled(model.email.isEmpty)
                        }
                    }
                    Section {
                        Text("Signing in opens a separate workspace for your account. You can choose to move your guest projects and voices into it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if model.isBusy { ProgressView("Please wait…") }
                if let message = model.message { Text(message).accessibilityAddTraits(.updatesFrequently) }
                if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            .disabled(model.isBusy)
            .navigationTitle("Account")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(model.isBusy)
                }
            }
            .confirmationDialog("Permanently delete your VoiceClone account?", isPresented: Binding(
                get: { confirmingDeletion && model.account?.usesApple == false },
                set: { confirmingDeletion = $0 }
            ), titleVisibility: .visible) {
                Button("Delete account", role: .destructive) { Task { await model.deleteWithPassword() } }
            }
        }
        .frame(minWidth: 320, minHeight: 480)
        .onDisappear { model.password = "" }
    }

    private var emailField: some View {
        TextField("Email", text: $model.email)
            .textContentType(.emailAddress)
            #if os(iOS)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            #endif
    }

    private func passwordField(creating: Bool) -> some View {
        SecureField("Password", text: $model.password)
            .textContentType(creating ? .newPassword : .password)
    }

    private func appleButton(_ action: AppleAccountAction) -> some View {
        let expectedAccountID = model.account?.id
        return AppleAccountButton(action: { await model.useApple($0, action: action, expectedAccountID: expectedAccountID) },
                                  reportError: { model.error = $0 })
    }
}
