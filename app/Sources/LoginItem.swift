import AppKit
import ServiceManagement

enum LoginItemStatus: Equatable {
    case off, enabled, requiresApproval, unavailable
    // A checked box represents a requested login item. Pending consent always
    // has an adjacent, actionable approval message rather than claiming readiness.
    var requested: Bool { self == .enabled || self == .requiresApproval }
}

@MainActor
struct LoginItemActions {
    let status: () -> LoginItemStatus
    let setRequested: (Bool) throws -> Void
    let openSettings: () -> Void
    static var live: LoginItemActions {
        LoginItemActions(status: {
            switch SMAppService.mainApp.status {
            case .notRegistered: return .off
            case .enabled: return .enabled
            case .requiresApproval: return .requiresApproval
            case .notFound: return .unavailable
            @unknown default: return .unavailable
            }
        }, setRequested: { enabled in
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        }, openSettings: { SMAppService.openSystemSettingsLoginItems() })
    }
}

@MainActor
final class LoginItemController {
    private let actions: LoginItemActions
    private(set) var status: LoginItemStatus
    private(set) var error: String?
    init(actions: LoginItemActions) {
        self.actions = actions
        status = actions.status()
    }
    func refresh() {
        let value = actions.status()
        if value != status { error = nil }
        status = value
    }
    func setRequested(_ enabled: Bool) {
        refresh()
        guard enabled != status.requested else { return }
        do { try actions.setRequested(enabled); error = nil }
        catch { self.error = error.localizedDescription }
        status = actions.status()
        if enabled && status == .requiresApproval { error = nil }
    }
    var helpTitle: String? {
        if error != nil { return "Login Setting Failed — Open Settings…" }
        if status == .requiresApproval { return "Approve Launch at Login…" }
        if status == .unavailable { return "Login Item Unavailable — Open Settings…" }
        return nil
    }
    func openSettings() { actions.openSettings() }
}
