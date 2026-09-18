import Foundation
import SakuraCordModels

nonisolated enum ServerOrderPlacement: Equatable {
    case before(GuildRailItem.RailIdentifier)
    case after(GuildRailItem.RailIdentifier)
    case end
}

nonisolated enum ServerOrderEditing {
    static func moving(
        _ source: GuildRailItem.RailIdentifier,
        to placement: ServerOrderPlacement,
        in layout: [GuildRailItem]
    ) -> [GuildRailItem] {
        var result = layout
        let moved: GuildRailItem
        if let index = result.firstIndex(where: { $0.id == source }) {
            moved = result.remove(at: index)
        } else if case .guild(let id) = source,
                  let index = result.firstIndex(where: {
                      if case .folder(let folder) = $0 { return folder.guildIDs.contains(id) }
                      return false
                  }),
                  case .folder(var folder) = result[index]
        {
            folder.guildIDs.removeAll { $0 == id }
            result[index] = .folder(folder)
            moved = .guild(id)
        } else {
            return layout
        }

        let target: GuildRailItem.RailIdentifier
        let after: Bool
        switch placement {
        case .end:
            result.append(moved)
            return removingEmptyFolders(result)
        case .before(let id): (target, after) = (id, false)
        case .after(let id): (target, after) = (id, true)
        }
        guard source != target else { return layout }
        if let index = result.firstIndex(where: { $0.id == target }) {
            // A folder header sits directly above its first server, so a
            // server dropped below the header joins the folder there.
            if after, case .guild(let movedID) = moved, case .folder(var folder) = result[index] {
                folder.guildIDs.insert(movedID, at: 0)
                result[index] = .folder(folder)
            } else {
                result.insert(moved, at: index + (after ? 1 : 0))
            }
        } else if case .guild(let id) = target,
                  let index = result.firstIndex(where: {
                      if case .folder(let folder) = $0 { return folder.guildIDs.contains(id) }
                      return false
                  }),
                  case .folder(var folder) = result[index],
                  let childIndex = folder.guildIDs.firstIndex(of: id)
        {
            if case .guild(let movedID) = moved {
                folder.guildIDs.insert(movedID, at: childIndex + (after ? 1 : 0))
                result[index] = .folder(folder)
            } else {
                // Folders remain top-level; dropping on a child moves beside its folder.
                result.insert(moved, at: index + (after ? 1 : 0))
            }
        } else {
            return layout
        }
        return removingEmptyFolders(result)
    }

    private static func removingEmptyFolders(_ layout: [GuildRailItem]) -> [GuildRailItem] {
        layout.filter {
            if case .folder(let folder) = $0 { return !folder.guildIDs.isEmpty }
            return true
        }
    }
}

extension AppModel {
    /// Discord's own client batches rapid rearrangement into one settings save
    /// ten seconds after the first unsaved change.
    static let serverLayoutSaveDelay: Duration = .seconds(10)

    var canReorderServers: Bool {
        supportedCapabilities.contains(.serverOrderEditing) && !isSwitchingAccounts && snapshot != nil
    }

    @discardableResult
    func moveServerItem(
        _ source: GuildRailItem.RailIdentifier,
        to placement: ServerOrderPlacement,
        accountID: String
    ) -> Bool {
        guard canReorderServers, snapshot?.currentUser.id.description == accountID else { return false }
        let next = ServerOrderEditing.moving(source, to: placement, in: serverRailItems)
        guard next != serverRailItems else { return false }
        serverRailItems = next
        pendingServerLayout = next
        scheduleServerLayoutSave()
        return true
    }

    /// Sends a pending rearrangement now, as when the server picker closes.
    /// Moves made while a save is in flight become one follow-up save.
    func saveServerLayout() {
        serverLayoutSaveTask?.cancel()
        serverLayoutSaveTask = nil
        guard !isSavingServerLayout, let layout = pendingServerLayout else { return }
        pendingServerLayout = nil
        isSavingServerLayout = true
        let session = accountSession()
        Task { [weak self] in
            let saved = try? await session.provider.updateGuildLayout(layout)
            guard let self, self.isCurrentAccountSession(session) else { return }
            self.isSavingServerLayout = false
            if self.pendingServerLayout != nil {
                self.saveServerLayout()
            } else if let saved {
                if !saved.isEmpty { self.serverRailItems = saved }
            } else {
                self.serverRailItems = self.snapshot?.guildRailItems ?? []
                self.errorMessage = "Discord did not accept the server order."
            }
        }
    }

    func discardPendingServerLayout() {
        serverLayoutSaveTask?.cancel()
        serverLayoutSaveTask = nil
        pendingServerLayout = nil
        isSavingServerLayout = false
    }

    private func scheduleServerLayoutSave() {
        guard serverLayoutSaveTask == nil else { return }
        let session = accountSession()
        serverLayoutSaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.serverLayoutSaveDelay)
            guard !Task.isCancelled, let self, self.isCurrentAccountSession(session) else { return }
            self.serverLayoutSaveTask = nil
            self.saveServerLayout()
        }
    }
}
