import AxoCore
import AxoEngineAPI
import AxoWeb
import Foundation

/// A site's lasting permission, by kind and origin.
struct LastingPermissionKey: Hashable {
    let kind: PermissionKind
    let origin: PageOrigin
}

extension ChromiumEngine {
    /// Keeps Chrome's own answer for notifications or the clipboard in step with Axo's site
    /// settings: Chrome keeps those answers, and pages read them without asking. Like bookmarks,
    /// the engine gets them once it's ready and the profile is in use, so setting them at launch
    /// doesn't load profiles nobody uses.
    public func setLastingPermission(_ kind: PermissionKind, origin: PageOrigin, decision: PermissionDecision?, profileID: Profile.ID) {
        guard kind.lastsInEngine, readyProfileIsAllowed(profileID) else { return }
        let key = LastingPermissionKey(kind: kind, origin: origin)
        lastingPermissions[profileID, default: [:]][key] = .some(decision)
        guard isFollowing(profileID) else { return }
        readyProfile(profileID)?.setLastingPermission(key, decision: decision)
    }
}

extension ChromiumEngine {
    /// Replaces the profile's lasting answers in Chrome with Axo's, clearing any Chrome has that
    /// Axo doesn't (a site Chrome revoked or blocked on its own). Like the others, applied once
    /// the profile is in use.
    public func replaceLastingPermissions(_ answers: [LastingPermission], profileID: Profile.ID) {
        guard readyProfileIsAllowed(profileID) else { return }
        var replacement: [LastingPermissionKey: PermissionDecision?] = [:]
        for answer in answers where answer.kind.lastsInEngine {
            replacement[LastingPermissionKey(kind: answer.kind, origin: answer.origin)] = .some(answer.decision)
        }
        lastingPermissions[profileID] = replacement
        clearsLastingPermissions.insert(profileID)
        guard isFollowing(profileID), let profile = readyProfile(profileID) else { return }
        clearsLastingPermissions.remove(profileID)
        profile.clearLastingPermissions()
        for (key, decision) in replacement {
            profile.setLastingPermission(key, decision: decision)
        }
    }

    /// Chromium asks Axo about every kind.
    public var askedPermissionKinds: Set<PermissionKind> { Set(PermissionKind.allCases) }
}

extension AXOProfile {
    func setLastingPermission(_ key: LastingPermissionKey, decision: PermissionDecision?) {
        guard let url = URL(string: key.origin.serialized) else { return }
        let kind: AXOPermissionKind
        switch key.kind {
        case .notifications: kind = .notifications
        case .clipboard: kind = .clipboard
        case .camera, .microphone, .cameraAndMicrophone, .location: return
        }
        let setting: AXOPermissionSetting = switch decision {
        case .allow: .allow
        case .deny: .block
        case nil: .ask
        }
        setPermission(kind, origin: url, setting: setting)
    }
}
