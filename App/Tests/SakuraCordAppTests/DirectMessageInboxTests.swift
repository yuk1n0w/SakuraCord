import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

@MainActor
@Test func `direct message inbox only includes existing private conversations`() {
    let maya = User(id: UserID(rawValue: 2), username: "maya.dev", displayName: "Maya")
    let theo = User(id: UserID(rawValue: 3), username: "theo", displayName: "Theodore")
    let channels = [
        Channel(
            id: ChannelID(rawValue: 40),
            guildID: nil,
            name: "Maya",
            kind: .directMessage,
            recipients: [maya]
        ),
        Channel(
            id: ChannelID(rawValue: 41),
            guildID: nil,
            name: "Design crew",
            kind: .groupDirectMessage,
            recipients: [maya, theo]
        ),
        Channel(
            id: ChannelID(rawValue: 42),
            guildID: GuildID(rawValue: 10),
            name: "maya-not-a-dm",
            kind: .text
        ),
    ]

    #expect(DirectMessageInboxPolicy.conversations(in: channels).map(\.id) == [
        ChannelID(rawValue: 40), ChannelID(rawValue: 41),
    ])
    #expect(DirectMessageInboxPolicy.secondaryText(for: channels[0]) == nil)
    #expect(
        DirectMessageInboxPolicy.secondaryText(for: channels[1])
            == "3 members"
    )
}

@Test func `direct message inbox resolves presence and custom status by recipient`() throws {
    let maya = User(id: UserID(rawValue: 2), username: "maya.dev", displayName: "Maya")
    let channel = Channel(
        id: ChannelID(rawValue: 40),
        guildID: nil,
        name: "Maya",
        kind: .directMessage,
        recipients: [maya]
    )
    let member = Member(
        user: maya,
        roleName: "Direct Message",
        status: .idle,
        customStatus: "  Shipping tiny details  "
    )

    let resolved = try #require(
        DirectMessageInboxPolicy.recipientMember(
            for: channel,
            membersByID: [maya.id: member]
        )
    )
    #expect(resolved.status == .idle)
    #expect(
        DirectMessageInboxPolicy.secondaryText(for: channel, member: resolved)
            == "Shipping tiny details"
    )
}

@Test func `direct message inbox only surfaces actively ringing calls`() {
    let channelID = ChannelID(rawValue: 40)
    let ongoing = PrivateCall(
        channelID: channelID,
        voiceStates: []
    )
    let ringing = PrivateCall(
        channelID: channelID,
        ongoingRings: [
            PrivateCallRing(
                recipientID: UserID(rawValue: 2),
                senderID: UserID(rawValue: 3)
            )
        ],
        voiceStates: []
    )

    #expect(DirectMessageInboxPolicy.callStatus(for: ongoing) == nil)
    #expect(DirectMessageInboxPolicy.callStatus(for: ringing) == "Ringing")
}

@MainActor
@Test func `selecting an existing direct message uses the shared timeline and profile`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let existing = try #require(
        model.snapshot?.channels.first {
            $0.kind == .directMessage && $0.recipients.count == 1
        }
    )
    let recipient = try #require(existing.recipients.first)
    let guildPresentationRevision = model.timelinePresentationRevision
    model.selectGuild(nil)
    #expect(await waitForDirectMessageCondition { model.selectedGuildID == nil })
    #expect(model.timelinePresentationRevision > guildPresentationRevision)
    model.selectedChannelID = existing.id
    #expect(await waitForDirectMessageCondition {
        model.selectedChannelID == existing.id
            && model.selectedChannel?.kind == .directMessage
    })
    model.showInspectorProfile(for: recipient)

    #expect(model.selectedGuildID == nil)
    #expect(model.selectedChannelID == existing.id)
    #expect(model.selectedChannel?.kind == .directMessage)
    #expect(model.inspectorProfilePresentation?.member.id == recipient.id)
}

@MainActor
@Test func `group direct messages retain the participant list inspector`() async throws {
    let provider = MockChatProvider()
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let group = try #require(
        model.snapshot?.channels.first { $0.kind == .groupDirectMessage }
    )

    model.selectGuild(nil)
    #expect(await waitForDirectMessageCondition { model.selectedGuildID == nil })
    model.selectedChannelID = group.id
    #expect(await waitForDirectMessageCondition {
        model.selectedChannelID == group.id
            && model.selectedChannel?.kind == .groupDirectMessage
    })
    let currentUserID = try #require(model.snapshot?.currentUser.id)
    #expect(
        Set(model.directMessageInspectorSections.flatMap(\.members).map(\.id))
            == Set(group.recipients.map(\.id) + [currentUserID])
    )
}

@MainActor
@Test func `direct message text bubbles align incoming and outgoing messages`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let recipient = User(
        id: UserID(rawValue: currentUser.id.rawValue + 10_000),
        username: "bubble-recipient",
        displayName: "Bubble Recipient"
    )
    let channelID = ChannelID(rawValue: 9_001)
    let width: CGFloat = 1_000

    func layout(author: User, content: String) -> NativeTimelineRowLayout {
        let row = MessageRowPresentation(
            message: Message(
                id: MessageID(rawValue: author.id.rawValue + 20_000),
                channelID: channelID,
                author: author,
                content: content
            ),
            startsGroup: true,
            startsDay: false,
            replyPreview: nil,
            isReplyAvailable: false
        )
        return NativeTimelineRowLayout.make(
            item: .message(
                row,
                isUnreadBoundary: false,
                isHighlighted: false
            ),
            width: width,
            model: model,
            presentationStyle: .directMessage
        )
    }

    let incoming = layout(author: recipient, content: "Incoming bubble")
    let outgoing = layout(author: currentUser, content: "Outgoing bubble")
    let incomingBubble = try #require(incoming.messageBubbleFrame)
    let outgoingBubble = try #require(outgoing.messageBubbleFrame)
    let incomingContent = try #require(incoming.contentFrame)
    let outgoingContent = try #require(outgoing.contentFrame)

    // The thread spans the pane: incoming anchors to the leading edge and
    // outgoing to the trailing one, rather than to a centred column.
    #expect(incomingBubble.minX == 24)
    #expect(outgoingBubble.maxX == width - 24)
    #expect(
        incomingBubble.width
            <= ChatChromeMetrics.directMessageBubbleMaximumWidth
    )
    // Bubbles take a share of the pane, never its full width, so the
    // opposite side stays visibly open.
    #expect(incomingBubble.width <= (width - 48) * 0.62)
    #expect(incomingBubble.contains(incomingContent))
    #expect(outgoingBubble.contains(outgoingContent))
    #expect(incoming.messageBubbleIsOutgoing == false)
    #expect(outgoing.messageBubbleIsOutgoing)
    #expect(incoming.avatarFrame == nil)
    #expect(outgoing.authorFrame == nil)
}

@MainActor
@Test func `direct message reactions stay inside the bubble presentation`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let recipient = User(
        id: UserID(rawValue: currentUser.id.rawValue + 11_000),
        username: "reaction-recipient",
        displayName: "Reaction Recipient"
    )
    let width: CGFloat = 1_000
    let row = MessageRowPresentation(
        message: Message(
            id: MessageID(rawValue: 31_000),
            channelID: ChannelID(rawValue: 9_101),
            author: recipient,
            content: "sounds good",
            reactions: [Reaction(emoji: "❤️", count: 1)]
        ),
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(row, isUnreadBoundary: false, isHighlighted: false),
        width: width,
        model: model,
        presentationStyle: .directMessage
    )

    // A reacted message keeps the bubble instead of dropping to an avatar row.
    let bubble = try #require(layout.messageBubbleFrame)
    #expect(layout.avatarFrame == nil)
    #expect(layout.authorFrame == nil)
    #expect(layout.reactionRegions.count == 1)

    // The chips hang below the bubble, on the same edge it is anchored to,
    // and the row grows to contain them.
    let reaction = try #require(layout.reactionRegions.first)
    #expect(reaction.frame.minY >= bubble.maxY)
    #expect(reaction.frame.minX == bubble.minX)
    #expect(layout.height > reaction.frame.maxY)
}

@MainActor
@Test func `direct message replies keep the bubble and quote above it`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let recipient = User(
        id: UserID(rawValue: currentUser.id.rawValue + 12_000),
        username: "reply-recipient",
        displayName: "Reply Recipient"
    )
    let channelID = ChannelID(rawValue: 9_201)
    let width: CGFloat = 1_000
    let parent = Message(
        id: MessageID(rawValue: 32_000),
        channelID: channelID,
        author: recipient,
        content: "u good with that?"
    )
    let row = MessageRowPresentation(
        // Type `.reply`, as Discord actually sends it. A `.default` message
        // carrying a replyPreview is a shape that never arrives, and testing
        // that let a broken guard pass.
        message: Message(
            id: MessageID(rawValue: 32_001),
            channelID: channelID,
            author: recipient,
            content: "test",
            type: .reply
        ),
        startsGroup: true,
        startsDay: false,
        replyPreview: MessageReplyPreview(message: parent),
        isReplyAvailable: true
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(row, isUnreadBoundary: false, isHighlighted: false),
        width: width,
        model: model,
        presentationStyle: .directMessage
    )

    // A reply stays a bubble rather than dropping to a full avatar row.
    let bubble = try #require(layout.messageBubbleFrame)
    let reply = try #require(layout.replyFrame)
    #expect(layout.avatarFrame == nil)
    #expect(layout.authorFrame == nil)

    // The quote sits above the bubble and shares its leading edge.
    #expect(reply.maxY <= bubble.minY)
    #expect(reply.minX == bubble.minX)
}

@MainActor
@Test func `direct message images stay in the bubble presentation`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let recipient = User(
        id: UserID(rawValue: currentUser.id.rawValue + 13_000),
        username: "image-recipient",
        displayName: "Image Recipient"
    )
    let channelID = ChannelID(rawValue: 9_301)
    let width: CGFloat = 1_000
    let attachment = Attachment(
        id: "attachment-1",
        filename: "photo.png",
        url: try #require(URL(string: "https://example.invalid/photo.png")),
        mediaType: "image/png",
        width: 800,
        height: 600
    )

    func layout(content: String) -> NativeTimelineRowLayout {
        let row = MessageRowPresentation(
            message: Message(
                id: MessageID(rawValue: 33_000),
                channelID: channelID,
                author: recipient,
                content: content,
                attachments: [attachment]
            ),
            startsGroup: true,
            startsDay: false,
            replyPreview: nil,
            isReplyAvailable: false
        )
        return NativeTimelineRowLayout.make(
            item: .message(row, isUnreadBoundary: false, isHighlighted: false),
            width: width,
            model: model,
            presentationStyle: .directMessage
        )
    }

    // An image sent without a caption still avoids the avatar row, and gets
    // no text bubble behind it since the media is its own surface.
    let bare = layout(content: "")
    let bareImage = try #require(bare.attachmentRegions.first)
    #expect(bare.avatarFrame == nil)
    #expect(bare.authorFrame == nil)
    #expect(bare.messageBubbleFrame == nil)
    #expect(bareImage.frame.minX == 24)
    #expect(bare.height > bareImage.frame.maxY)

    // With a caption the bubble stays and the image sits under it, both on
    // the same edge.
    let captioned = layout(content: "look at this")
    let captionBubble = try #require(captioned.messageBubbleFrame)
    let captionImage = try #require(captioned.attachmentRegions.first)
    #expect(captionImage.frame.minY >= captionBubble.maxY)
    #expect(captionImage.frame.minX == captionBubble.minX)
}

@MainActor
@Test func `group direct message bubbles name incoming senders`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let sender = User(
        id: UserID(rawValue: currentUser.id.rawValue + 14_000),
        username: "group-sender",
        displayName: "Group Sender"
    )
    let channelID = ChannelID(rawValue: 9_401)

    func layout(
        author: User,
        startsGroup: Bool,
        style: NativeTimelinePresentationStyle
    ) -> NativeTimelineRowLayout {
        let row = MessageRowPresentation(
            message: Message(
                id: MessageID(rawValue: author.id.rawValue + 34_000),
                channelID: channelID,
                author: author,
                content: "who said this"
            ),
            startsGroup: startsGroup,
            startsDay: false,
            replyPreview: nil,
            isReplyAvailable: false
        )
        return NativeTimelineRowLayout.make(
            item: .message(row, isUnreadBoundary: false, isHighlighted: false),
            width: 1_000,
            model: model,
            presentationStyle: style
        )
    }

    // In a group the sender is named once per run of incoming messages.
    let firstIncoming = layout(
        author: sender,
        startsGroup: true,
        style: .groupDirectMessage
    )
    let namePlate = try #require(firstIncoming.authorFrame)
    let bubble = try #require(firstIncoming.messageBubbleFrame)
    #expect(namePlate.maxY <= bubble.minY)
    #expect(firstIncoming.avatarFrame == nil)

    // Not repeated mid-run, never shown for your own messages, and never in
    // a one-to-one thread.
    #expect(
        layout(author: sender, startsGroup: false, style: .groupDirectMessage)
            .authorFrame == nil
    )
    #expect(
        layout(author: currentUser, startsGroup: true, style: .groupDirectMessage)
            .authorFrame == nil
    )
    #expect(
        layout(author: sender, startsGroup: true, style: .directMessage)
            .authorFrame == nil
    )
}

@MainActor
@Test func `edited direct messages are marked under the bubble`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let recipient = User(
        id: UserID(rawValue: currentUser.id.rawValue + 15_000),
        username: "edit-recipient",
        displayName: "Edit Recipient"
    )
    let channelID = ChannelID(rawValue: 9_501)

    func layout(edited: Bool) -> NativeTimelineRowLayout {
        let row = MessageRowPresentation(
            message: Message(
                id: MessageID(rawValue: 35_000),
                channelID: channelID,
                author: recipient,
                content: "typo fixed",
                editedTimestamp: edited ? Date(timeIntervalSince1970: 1) : nil
            ),
            startsGroup: true,
            startsDay: false,
            replyPreview: nil,
            isReplyAvailable: false
        )
        return NativeTimelineRowLayout.make(
            item: .message(row, isUnreadBoundary: false, isHighlighted: false),
            width: 1_000,
            model: model,
            presentationStyle: .directMessage
        )
    }

    // An edited message is distinguishable from what was originally sent.
    let edited = layout(edited: true)
    let bubble = try #require(edited.messageBubbleFrame)
    let marker = try #require(edited.editedFrame)
    #expect(marker.minY >= bubble.maxY)
    #expect(marker.minX == bubble.minX)
    #expect(edited.height > marker.maxY)

    // An unedited message carries no marker and stays shorter for it.
    let untouched = layout(edited: false)
    #expect(untouched.editedFrame == nil)
    #expect(untouched.height < edited.height)
}

@MainActor
@Test func `direct message link previews hang below the bubble`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let recipient = User(
        id: UserID(rawValue: currentUser.id.rawValue + 16_000),
        username: "embed-recipient",
        displayName: "Embed Recipient"
    )
    let row = MessageRowPresentation(
        message: Message(
            id: MessageID(rawValue: 36_000),
            channelID: ChannelID(rawValue: 9_601),
            author: recipient,
            content: "look at this",
            embeds: [
                MessageEmbed(
                    title: "A page",
                    description: "With a description",
                    url: URL(string: "https://example.invalid/page")
                ),
            ]
        ),
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(row, isUnreadBoundary: false, isHighlighted: false),
        width: 1_000,
        model: model,
        presentationStyle: .directMessage
    )

    // A link preview keeps the message in the bubble presentation instead of
    // dropping it to a full avatar row.
    let bubble = try #require(layout.messageBubbleFrame)
    let embed = try #require(layout.embedFrames.first)
    #expect(layout.avatarFrame == nil)
    #expect(layout.authorFrame == nil)

    // The preview sits under the message, and the row grows to contain it.
    #expect(embed.minY >= bubble.maxY)
    #expect(layout.height > embed.maxY)
}

@MainActor
@Test func `forwarded direct messages show their content in a bubble`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let sender = User(
        id: UserID(rawValue: currentUser.id.rawValue + 17_000),
        username: "forward-sender",
        displayName: "Forward Sender"
    )
    let row = MessageRowPresentation(
        // A forward is a shell: its own content is empty and what the reader
        // sees lives in the snapshot.
        message: Message(
            id: MessageID(rawValue: 37_000),
            channelID: ChannelID(rawValue: 9_701),
            author: sender,
            content: "",
            forwardedSnapshot: ForwardedMessageSnapshot(
                content: "the original text",
                timestamp: Date(timeIntervalSince1970: 1)
            )
        ),
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(row, isUnreadBoundary: false, isHighlighted: false),
        width: 1_000,
        model: model,
        presentationStyle: .directMessage
    )

    // The forwarded text is rendered rather than an empty bubble, and the
    // message keeps the bubble presentation instead of an avatar row.
    let bubble = try #require(layout.messageBubbleFrame)
    let header = try #require(layout.forwardedHeaderFrame)
    #expect(layout.avatarFrame == nil)
    #expect(layout.attributedContent?.string.contains("the original text") == true)

    // The header labels it, sitting above the bubble.
    #expect(header.maxY <= bubble.minY)
}

@MainActor
@Test func `direct message stickers stay in the bubble presentation`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let sender = User(
        id: UserID(rawValue: currentUser.id.rawValue + 18_000),
        username: "sticker-sender",
        displayName: "Sticker Sender"
    )
    let row = MessageRowPresentation(
        message: Message(
            id: MessageID(rawValue: 38_000),
            channelID: ChannelID(rawValue: 9_801),
            author: sender,
            content: "",
            stickers: [MessageSticker(id: "1", name: "wave")]
        ),
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let layout = NativeTimelineRowLayout.make(
        item: .message(row, isUnreadBoundary: false, isHighlighted: false),
        width: 1_000,
        model: model,
        presentationStyle: .directMessage
    )

    // A sticker keeps the thread in bubbles rather than dropping an avatar
    // row, and like an image it carries no bubble of its own.
    let sticker = try #require(layout.stickerFrames.first)
    #expect(layout.avatarFrame == nil)
    #expect(layout.messageBubbleFrame == nil)
    #expect(sticker.minX == 24)
    #expect(layout.height > sticker.maxY)
}

@MainActor
@Test func `direct message bubble styling does not alter standard or rich rows`() {
    let author = User(
        id: UserID(rawValue: 7_001),
        username: "fixture",
        displayName: "Fixture"
    )
    let plainRow = MessageRowPresentation(
        message: Message(
            id: MessageID(rawValue: 7_002),
            channelID: ChannelID(rawValue: 7_003),
            author: author,
            content: "Plain text"
        ),
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    let codeRow = MessageRowPresentation(
        message: Message(
            id: MessageID(rawValue: 7_004),
            channelID: ChannelID(rawValue: 7_003),
            author: author,
            content: "```swift\nlet value = 1\n```"
        ),
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )
    // A generated system message is not conversation text, so it keeps the
    // standard presentation even inside a direct message.
    let systemRow = MessageRowPresentation(
        message: Message(
            id: MessageID(rawValue: 7_005),
            channelID: ChannelID(rawValue: 7_003),
            author: author,
            content: "pinned a message",
            type: .channelPinnedMessage
        ),
        startsGroup: true,
        startsDay: false,
        replyPreview: nil,
        isReplyAvailable: false
    )

    let standard = NativeTimelineRowLayout.make(
        item: .message(
            plainRow,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 640,
        presentationStyle: .standard
    )
    let codeDirectMessage = NativeTimelineRowLayout.make(
        item: .message(
            codeRow,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 640,
        presentationStyle: .directMessage
    )
    let systemDirectMessage = NativeTimelineRowLayout.make(
        item: .message(
            systemRow,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 640,
        presentationStyle: .directMessage
    )

    // A standard channel is untouched by any of the bubble work.
    #expect(standard.messageBubbleFrame == nil)
    #expect(standard.avatarFrame != nil)

    // Code is conversation text, so it gets a bubble, and takes the full
    // width allowed rather than being sized to its longest line.
    #expect(codeDirectMessage.messageBubbleFrame != nil)
    #expect(codeDirectMessage.avatarFrame == nil)

    // A generated notice - a call, a name change - is not conversation, so
    // it carries no bubble. It is a quiet centred line rather than the
    // standard row's icon and gutter, which is Discord chrome around what
    // is really one sentence.
    #expect(systemDirectMessage.messageBubbleFrame == nil)
    #expect(systemDirectMessage.systemIconFrame == nil)
    #expect(systemDirectMessage.avatarFrame == nil)
}

@MainActor
@Test func `group direct message participants reconcile a partial owner payload`() {
    let currentUser = User(
        id: UserID(rawValue: 1),
        username: "current",
        displayName: "Current"
    )
    let owner = User(
        id: UserID(rawValue: 2),
        username: "owner",
        displayName: "Owner"
    )
    let recipient = User(
        id: UserID(rawValue: 3),
        username: "recipient",
        displayName: "Recipient"
    )
    let channel = Channel(
        id: ChannelID(rawValue: 40),
        guildID: nil,
        name: "Group",
        ownerID: owner.id,
        kind: .groupDirectMessage,
        recipients: [currentUser, recipient]
    )
    let members = DirectMessageMemberResolver.members(
        for: channel,
        knownMembers: [
            Member(user: owner, roleName: "Members", status: .offline),
            Member(user: recipient, roleName: "Members", status: .online),
        ],
        currentUser: currentUser,
        currentStatus: .offline
    )

    #expect(members.map(\.id) == [recipient.id, owner.id, currentUser.id])
    #expect(Set(members.map(\.id)).count == 3)
    #expect(MemberSection.make(from: members).flatMap(\.members).count == 3)
}

@MainActor
@Test func `official Discord system direct messages are read only`() {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    let officialUser = User(
        id: UserID(rawValue: 99),
        username: "discord",
        displayName: "Discord",
        isSystem: true
    )
    let officialChannel = Channel(
        id: ChannelID(rawValue: 50),
        guildID: nil,
        name: "Discord",
        kind: .directMessage,
        recipients: [officialUser]
    )
    let ordinaryChannel = Channel(
        id: ChannelID(rawValue: 51),
        guildID: nil,
        name: "Maya",
        kind: .directMessage,
        recipients: [
            User(
                id: UserID(rawValue: 2),
                username: "maya",
                displayName: "Maya"
            )
        ]
    )

    #expect(officialChannel.isOfficialSystemDirectMessage)
    #expect(
        model.conversationAccess(for: officialChannel)
            == .readable(canSend: false)
    )
    #expect(
        model.conversationAccess(for: ordinaryChannel)
            == .readable(canSend: true)
    )
}

@MainActor
private func waitForDirectMessageCondition(
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

@MainActor
@Test func `direct message linked images sit on the sender's edge`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let other = User(
        id: UserID(rawValue: currentUser.id.rawValue + 21_000),
        username: "gif-sender",
        displayName: "Gif Sender"
    )
    let width: CGFloat = 1_000

    // A GIF shared as a link rather than an upload: the media arrives as a
    // linked image, not an attachment.
    func layout(author: User) -> NativeTimelineRowLayout {
        let row = MessageRowPresentation(
            message: Message(
                id: MessageID(rawValue: author.id.rawValue + 41_000),
                channelID: ChannelID(rawValue: 9_501),
                author: author,
                content: "[reaction.gif](https://cdn.discordapp.com/a/reaction.gif)"
            ),
            startsGroup: true,
            startsDay: false,
            replyPreview: nil,
            isReplyAvailable: false
        )
        return NativeTimelineRowLayout.make(
            item: .message(row, isUnreadBoundary: false, isHighlighted: false),
            width: width,
            model: model,
            presentationStyle: .directMessage
        )
    }

    let outgoing = layout(author: currentUser)
    let incoming = layout(author: other)

    // A linked image is media like any other, so it belongs to a bubble row
    // instead of falling back to the standard layout.
    let outgoingImage = try #require(outgoing.linkedImageRegions.first)
    let incomingImage = try #require(incoming.linkedImageRegions.first)

    // The sender's own GIF hangs off the trailing edge; everyone else's off
    // the leading edge. Before this, both landed on the left because a
    // linked image dropped the row out of the conversation layout.
    #expect(outgoingImage.frame.maxX > width / 2)
    #expect(incomingImage.frame.minX < width / 2)
    #expect(outgoingImage.frame.minX > incomingImage.frame.minX)

    // Media on its own still gets a highlight shaped to the media rather
    // than the full-width band a standard row would draw.
    let highlight = try #require(outgoing.highlightBackgroundFrame)
    #expect(highlight.width < width)
}

@MainActor
@Test func `direct message embed media sits on the sender's edge`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let other = User(
        id: UserID(rawValue: currentUser.id.rawValue + 26_000),
        username: "embed-sender",
        displayName: "Embed Sender"
    )
    let width: CGFloat = 1_000
    let source = try #require(URL(string: "https://example.com/view/loop.gif"))

    // A GIF sent from the picker: the text is the source URL, and the
    // bare-media embed replaces it, so the message has no visible content
    // of its own.
    func layout(author: User) -> NativeTimelineRowLayout {
        let row = MessageRowPresentation(
            message: Message(
                id: MessageID(rawValue: author.id.rawValue + 46_000),
                channelID: ChannelID(rawValue: 9_601),
                author: author,
                content: source.absoluteString,
                embeds: [
                    MessageEmbed(
                        type: "gifv",
                        url: source,
                        video: MessageEmbedMedia(
                            url: source,
                            width: 320,
                            height: 240
                        )
                    )
                ]
            ),
            startsGroup: true,
            startsDay: false,
            replyPreview: nil,
            isReplyAvailable: false
        )
        return NativeTimelineRowLayout.make(
            item: .message(row, isUnreadBoundary: false, isHighlighted: false),
            width: width,
            model: model,
            presentationStyle: .directMessage
        )
    }

    let outgoing = layout(author: currentUser)
    let incoming = layout(author: other)

    // The embed is the whole message, so it still belongs to a conversation
    // row rather than falling back to the standard left-aligned one.
    let outgoingEmbed = try #require(outgoing.embedFrames.first)
    let incomingEmbed = try #require(incoming.embedFrames.first)

    #expect(outgoingEmbed.maxX > width / 2)
    #expect(incomingEmbed.minX < width / 2)
    #expect(outgoingEmbed.minX > incomingEmbed.minX)

    // With no bubble behind it, the highlight follows the media instead of
    // spanning the pane.
    let highlight = try #require(outgoing.highlightBackgroundFrame)
    #expect(highlight.width < width)
}

@MainActor
@Test func `direct message system notices render as centred lines`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let currentUser = try #require(model.snapshot?.currentUser)
    let width: CGFloat = 1_000

    var message = Message(
        id: MessageID(rawValue: 51_000),
        channelID: ChannelID(rawValue: 9_701),
        author: currentUser,
        content: ""
    )
    message.type = .call
    let layout = NativeTimelineRowLayout.make(
        item: .message(
            MessageRowPresentation(
                message: message,
                startsGroup: true,
                startsDay: false,
                replyPreview: nil,
                isReplyAvailable: false
            ),
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: width,
        model: model,
        presentationStyle: .directMessage
    )

    // A call is not conversation, so it carries no bubble and is not
    // attributed to a sender the way a message is.
    #expect(layout.messageBubbleFrame == nil)
    #expect(layout.authorFrame == nil)
    #expect(layout.avatarFrame == nil)

    // It sits centred in the pane rather than on either edge.
    let content = try #require(layout.contentFrame)
    let centreOffset = abs(content.midX - width / 2)
    #expect(centreOffset < 1)

    // The row is measured from the line itself; without that it claims no
    // height and the next message draws over it.
    #expect(layout.height > content.height)
}

@MainActor
@Test func `conversation nicknames take a stable colour from the account`() {
    func user(_ id: UInt64, name: String, isBot: Bool = false) -> User {
        User(
            id: UserID(rawValue: id),
            username: name,
            displayName: name,
            isBot: isBot
        )
    }

    // A group conversation has no roles, so the name is coloured from the
    // account itself the way an IRC client coloured a nick.
    let speaker = user(4_820_017, name: "marcos")
    let conversation = NativeTimelineRowPainter.authorNameColor(
        speaker,
        roleColorHex: nil,
        usesConversationLayout: true
    )
    #expect(conversation != .labelColor)
    #expect(RetroNickPalette.colors.contains(conversation))

    // The same account keeps its colour: it is derived from the identifier,
    // not from position in the member list or the order messages arrive.
    #expect(
        conversation == NativeTimelineRowPainter.authorNameColor(
            user(4_820_017, name: "renamed-since"),
            roleColorHex: nil,
            usesConversationLayout: true
        )
    )

    // A server still names people by role: the retro palette would override
    // a colour that carries real meaning there.
    let role = NativeTimelineRowPainter.authorNameColor(
        speaker,
        roleColorHex: 0x00FF_7F00,
        usesConversationLayout: false
    )
    #expect(!RetroNickPalette.colors.contains(role))

    // A bot stays marked as one wherever it speaks.
    #expect(
        NativeTimelineRowPainter.authorNameColor(
            user(9_001, name: "helper", isBot: true),
            roleColorHex: nil,
            usesConversationLayout: true
        ) == .controlAccentColor
    )
}

@MainActor
@Test func `conversation timestamps read as bracketed twenty-four hour`() throws {
    var components = DateComponents()
    components.year = 1999
    components.month = 12
    components.day = 31
    components.hour = 14
    components.minute = 7
    let afternoon = try #require(Calendar.current.date(from: components))

    // The bracketed, zero-padded, twenty-four hour form every IRC client
    // printed. A locale-formatted stamp would drift to "2:07 PM", which
    // neither brackets nor sits in a monospaced column.
    #expect(
        NativeTimelineTimestamp.conversationText(for: afternoon)
            == "[14:07]"
    )

    components.hour = 0
    components.minute = 5
    let midnight = try #require(Calendar.current.date(from: components))
    #expect(
        NativeTimelineTimestamp.conversationText(for: midnight)
            == "[00:05]"
    )
}
