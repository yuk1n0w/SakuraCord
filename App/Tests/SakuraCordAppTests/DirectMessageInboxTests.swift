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

@Test func `nameplate presentation matches Paicord palette and hover opacity`() {
    #expect(
        NameplatePresentationPolicy.colors(for: "violet")
            == NameplatePaletteColors(light: 0x972FED, dark: 0x730BC8)
    )
    #expect(NameplatePresentationPolicy.colors(for: "none") == nil)
    #expect(NameplatePresentationPolicy.colors(for: "unknown") == nil)
    #expect(NameplatePresentationPolicy.opacity(isHovered: false) == 0.5)
    #expect(NameplatePresentationPolicy.opacity(isHovered: true) == 0.8)
}

@Test func `composer prompts distinguish private conversations from channels`() {
    #expect(
        ComposerPlaceholderPolicy.text(
            channelName: "Maya Ortiz",
            channelKind: .directMessage,
            destination: .channel
        ) == "Message @Maya Ortiz"
    )
    #expect(
        ComposerPlaceholderPolicy.text(
            channelName: "Design crew",
            channelKind: .groupDirectMessage,
            destination: .channel
        ) == "Message @Design crew"
    )
    #expect(
        ComposerPlaceholderPolicy.text(
            channelName: "general",
            channelKind: .text,
            destination: .channel
        ) == "Message #general"
    )
    #expect(
        ComposerPlaceholderPolicy.text(
            channelName: "support thread",
            channelKind: .directMessage,
            destination: .thread
        ) == "Message #support thread"
    )
}

@MainActor
@Test(.timeLimit(.minutes(1)))
func `large direct message inbox filtering remains bounded`() {
    let channels = (0 ..< 10_000).map { index in
        let user = User(
            id: UserID(rawValue: UInt64(index + 2)),
            username: "person-\(index)",
            displayName: "Person \(index)"
        )
        return Channel(
            id: ChannelID(rawValue: UInt64(index + 100)),
            guildID: nil,
            name: user.displayName,
            kind: .directMessage,
            recipients: [user]
        )
    }

    #expect(
        DirectMessageInboxPolicy.conversations(in: channels).count == 10_000
    )
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
        message: Message(
            id: MessageID(rawValue: 32_001),
            channelID: channelID,
            author: recipient,
            content: "test"
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
    let richRow = MessageRowPresentation(
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

    let standard = NativeTimelineRowLayout.make(
        item: .message(
            plainRow,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 640,
        presentationStyle: .standard
    )
    let richDirectMessage = NativeTimelineRowLayout.make(
        item: .message(
            richRow,
            isUnreadBoundary: false,
            isHighlighted: false
        ),
        width: 640,
        presentationStyle: .directMessage
    )

    #expect(standard.messageBubbleFrame == nil)
    #expect(standard.avatarFrame != nil)
    #expect(richDirectMessage.messageBubbleFrame == nil)
    #expect(richDirectMessage.avatarFrame != nil)
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
@Test func `changing conversations dismisses an open group member profile`() async throws {
    let model = AppModel(
        launchMode: .offlineTesting,
        provider: MockChatProvider()
    )
    await model.start()
    let group = try #require(
        model.snapshot?.channels.first { $0.kind == .groupDirectMessage }
    )
    let directMessage = try #require(
        model.snapshot?.channels.first { $0.kind == .directMessage }
    )
    let member = try #require(group.recipients.first)

    model.selectGuild(nil)
    #expect(await waitForDirectMessageCondition { model.selectedGuildID == nil })
    model.selectedChannelID = group.id
    #expect(await waitForDirectMessageCondition {
        model.selectedChannelID == group.id
    })
    model.selectMember(
        Member(user: member, roleName: "Direct Message", status: .offline)
    )
    #expect(model.isInspectorProfilePresented)

    model.selectedChannelID = directMessage.id

    #expect(!model.isInspectorProfilePresented)
    #expect(model.inspectorProfilePresentation == nil)
}

@MainActor
@Test func `profile banners stay constrained to their presentation width`() {
    #expect(ProfileBannerLayout.constrainedWidth(280) == 280)
    #expect(ProfileBannerLayout.constrainedWidth(MemberProfilePopover.preferredWidth) == 330)
    #expect(ProfileBannerLayout.constrainedWidth(-20) == 0)
    #expect(ProfileBannerLayout.constrainedWidth(.infinity) == 0)
}

@MainActor
@Test func `positioned profile effect layers retain the canonical canvas`() throws {
    let animation = ProfileEffectAnimation(
        sourceURL: try #require(URL(string: "https://cdn.example/profile-effect.png")),
        width: 250,
        height: 400
    )

    let frame = try #require(ProfileEffectLayout.frames(
        for: [animation],
        containerWidth: MemberProfilePopover.preferredWidth
    ).first)

    #expect(ProfileEffectLayout.designWidth(for: [animation]) == 450)
    #expect(frame.width == 183.33333333333331)
    #expect(frame.height == 293.3333333333333)
}

@MainActor
@Test func `dimensionless profile effect layers use the canonical profile canvas`() throws {
    let animation = ProfileEffectAnimation(
        sourceURL: try #require(URL(string: "https://cdn.example/dimensionless-effect.png"))
    )
    let frame = try #require(ProfileEffectLayout.frames(for: [animation], containerWidth: 330).first)

    #expect(ProfileEffectLayout.designWidth(for: [animation]) == 450)
    #expect(frame == CGRect(x: 0, y: 0, width: 330, height: 645.3333333333333))
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
