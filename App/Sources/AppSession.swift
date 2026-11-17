import Foundation
import Observation
import VoiceCloneCore
import VoiceCloneInfrastructure

@MainActor
@Observable
final class AppSession {
    let account: AccountViewModel
    private let service: (any AccountAuthenticating)?
    private let workspaces: AccountWorkspaces
    private let models = StudioModelCache()
    private(set) var studio: StudioViewModel?
    private(set) var workspaceID: String?
    var offersGuestTransfer = false
    var error: String?

    init(root: URL, service: (any AccountAuthenticating)?) {
        self.service = service
        workspaces = AccountWorkspaces(root: root)
        let storage = workspaces
        account = AccountViewModel(service: service, removeLocalData: { try storage.remove(accountID: $0) })
    }

    func observe() async {
        do { try workspaces.finishPendingTransfer() }
        catch {
            self.error = "Could not finish moving your guest workspace. \(error.localizedDescription)"
            return
        }
        guard let service else {
            await open(nil)
            return
        }
        for await user in service.accountChanges() {
            guard !Task.isCancelled else { return }
            account.update(user)
            if studio == nil || workspaceID != user?.id { await open(user?.id) }
        }
    }

    func transferGuest() async {
        guard let id = workspaceID else { return }
        offersGuestTransfer = false
        await studio?.cancelAndWait()
        do {
            try workspaces.transferGuest(to: id)
            studio = makeStudio(root: workspaces.directory(for: id))
        } catch { self.error = error.localizedDescription }
    }

    private func open(_ id: String?) async {
        offersGuestTransfer = false
        let previous = studio
        studio = nil
        await previous?.cancelAndWait()
        workspaceID = id
        studio = makeStudio(root: workspaces.directory(for: id))
        if let id { offersGuestTransfer = workspaces.canTransferGuest(to: id) }
    }

    private func makeStudio(root: URL) -> StudioViewModel {
        StudioViewModel(store: LocalStudioWorkspace(root: root),
                        renderer: LocalStudioRenderer(models: models), models: models)
    }
}
