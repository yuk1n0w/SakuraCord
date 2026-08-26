import DiscordProtocol
import SakuraCordModels

extension AppModel {
    var selectedConversationAccess: ConversationAccess {
        guard let channel = selectedChannel else { return .checking }
        return conversationAccess(for: channel)
    }

    var canCreateForumPosts: Bool {
        selectedConversationAccess.canSend
            && supportedCapabilities.contains(.forums)
    }

    var canManageForumPosts: Bool {
        guard let permissions = selectedEffectivePermissions else { return false }
        return permissions & DiscordPermissionBits.manageThreads != 0
    }

    func canDeleteForumPost(_ post: ForumPost) -> Bool {
        Self.canDeleteForumPost(
            ownerID: post.thread.ownerID ?? post.owner?.id,
            currentUserID: snapshot?.currentUser.id,
            canManage: canManageForumPosts
        )
    }

    func canArchiveForumPost(_ post: ForumPost) -> Bool {
        if canManageForumPosts { return true }
        guard !post.thread.isLocked else { return false }
        let ownerID = post.thread.ownerID ?? post.owner?.id
        return ownerID != nil && ownerID == snapshot?.currentUser.id
    }

    func canEditForumPostTags(_ post: ForumPost) -> Bool {
        if canManageForumPosts { return true }
        guard !post.thread.isLocked else { return false }
        let ownerID = post.thread.ownerID ?? post.owner?.id
        return ownerID != nil && ownerID == snapshot?.currentUser.id
    }

    func canToggleForumTag(_ tag: ForumTag, on post: ForumPost) -> Bool {
        guard canEditForumPostTags(post), canManageForumPosts || !tag.isModerated else {
            return false
        }
        if selectedChannel?.requiresForumTag == true,
           post.thread.appliedTagIDs.count == 1,
           post.thread.appliedTagIDs.contains(tag.id)
        {
            return false
        }
        return true
    }

    nonisolated static func canDeleteForumPost(
        ownerID: UserID?,
        currentUserID: UserID?,
        canManage: Bool
    ) -> Bool {
        canManage || (ownerID != nil && ownerID == currentUserID)
    }
}
