import Foundation
import SakuraCordModels

nonisolated struct ComposerDraftEdit: Equatable {
    let text: String
    let selection: NSRange
}

nonisolated enum ComposerControlPolicy {
    /// A one-to-one or group conversation, which is where the retro chrome
    /// applies. A server keeps the app's ordinary controls and typography.
    static func usesConversationChrome(
        channelKind: ChannelKindValue?,
        destination: MessageComposerDestination
    ) -> Bool {
        guard destination == .channel else { return false }
        return channelKind == .directMessage || channelKind == .groupDirectMessage
    }

    /// The GIF and emoji pickers are Discord's furniture standing beside a
    /// prompt that reads like a terminal's, and a conversation drops them.
    /// Neither is the only way in: `:name:` still completes emoji inline,
    /// and a pasted GIF link still renders as a GIF.
    static func showsPickers(
        channelKind: ChannelKindValue?,
        destination: MessageComposerDestination
    ) -> Bool {
        !usesConversationChrome(channelKind: channelKind, destination: destination)
    }

    /// A conversation keeps the send button only where it is an affordance
    /// rather than a second Return key. When Return sends, the button
    /// duplicates the key that already sent the message; when Return inserts
    /// a newline instead, the button and Command-Return are the only ways to
    /// send at all, so dropping it would strand the message.
    static func showsSendButton(
        channelKind: ChannelKindValue?,
        destination: MessageComposerDestination,
        sendsWithReturn: Bool
    ) -> Bool {
        !usesConversationChrome(channelKind: channelKind, destination: destination)
            || !sendsWithReturn
    }
}

nonisolated enum ComposerPlaceholderPolicy {
    static func text(
        channelName: String,
        channelKind: ChannelKindValue?,
        destination: MessageComposerDestination
    ) -> String {
        if ComposerControlPolicy.usesConversationChrome(
            channelKind: channelKind,
            destination: destination
        ) {
            // The conversation's input carries a prompt, the way a terminal
            // client's did. A server keeps the plain label: the prompt is
            // part of the conversation's own character, not the app's.
            return "> Message @\(channelName)"
        }
        return "Message #\(channelName)"
    }
}

nonisolated enum ComposerDraftEditing {
    static func insert(
        _ insertedText: String,
        into source: String,
        replacing selection: NSRange?
    ) -> ComposerDraftEdit {
        let resolved = resolvedRange(selection, in: source)
        var value = source
        let range = Range(resolved, in: value) ?? (value.endIndex ..< value.endIndex)
        value.replaceSubrange(range, with: insertedText)
        return ComposerDraftEdit(
            text: value,
            selection: NSRange(location: resolved.location + insertedText.utf16.count, length: 0)
        )
    }

    static func insertCustomEmoji(
        _ token: String,
        into source: String,
        replacing selection: NSRange?
    ) -> ComposerDraftEdit {
        insert(token, into: source, replacing: selection)
    }

    private static func resolvedRange(_ selection: NSRange?, in source: String) -> NSRange {
        let end = NSRange(location: source.utf16.count, length: 0)
        guard let selection,
              selection.location != NSNotFound,
              selection.location >= 0,
              selection.length >= 0,
              selection.location <= source.utf16.count,
              selection.length <= source.utf16.count - selection.location,
              Range(selection, in: source) != nil
        else { return end }
        return selection
    }
}
