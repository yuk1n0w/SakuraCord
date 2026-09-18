import DiscordProtocol
import Foundation
import SakuraCordModels
import Testing
@testable import SakuraCord

private func guildID(_ value: UInt64) -> GuildID { GuildID(rawValue: value) }

@Test func `server reorder moves in both directions and preserves folder membership`() {
    let layout: [GuildRailItem] = [
        .guild(guildID(1)),
        .folder(GuildFolder(id: 10, name: "Friends", guildIDs: [guildID(2), guildID(3)])),
        .guild(guildID(4)),
    ]
    let intoFolder = ServerOrderEditing.moving(.guild(guildID(1)), to: .after(.guild(guildID(2))), in: layout)
    #expect(intoFolder == [
        .folder(GuildFolder(id: 10, name: "Friends", guildIDs: [guildID(2), guildID(1), guildID(3)])),
        .guild(guildID(4)),
    ])
    let back = ServerOrderEditing.moving(.guild(guildID(1)), to: .before(.folder(10)), in: intoFolder)
    #expect(back == layout)
    let within = ServerOrderEditing.moving(.guild(guildID(3)), to: .before(.guild(guildID(2))), in: layout)
    #expect(within == [
        .guild(guildID(1)),
        .folder(GuildFolder(id: 10, name: "Friends", guildIDs: [guildID(3), guildID(2)])),
        .guild(guildID(4)),
    ])
    let wholeFolder = ServerOrderEditing.moving(.folder(10), to: .end, in: layout)
    #expect(wholeFolder == [layout[0], layout[2], layout[1]])
    #expect(ServerOrderEditing.moving(.folder(10), to: .before(.guild(guildID(2))), in: layout) == layout)
    #expect(ServerOrderEditing.moving(.guild(guildID(1)), to: .after(.guild(guildID(1))), in: layout) == layout)
    #expect(ServerOrderEditing.moving(.guild(guildID(1)), to: .after(.guild(guildID(99))), in: layout) == layout)
}

@Test func `moving the last child out removes only the empty folder`() {
    let layout: [GuildRailItem] = [
        .folder(GuildFolder(id: 10, guildIDs: [guildID(1)])), .guild(guildID(2)),
    ]
    #expect(ServerOrderEditing.moving(.guild(guildID(1)), to: .end, in: layout) == [
        .guild(guildID(2)), .guild(guildID(1)),
    ])
}

@Test func `dropping a server below a folder header makes it the folder's first server`() {
    let layout: [GuildRailItem] = [
        .folder(GuildFolder(id: 10, name: "Friends", guildIDs: [guildID(2), guildID(3)])),
        .guild(guildID(1)),
        .folder(GuildFolder(id: 20, guildIDs: [guildID(4)])),
    ]
    #expect(ServerOrderEditing.moving(.guild(guildID(1)), to: .after(.folder(10)), in: layout) == [
        .folder(GuildFolder(id: 10, name: "Friends", guildIDs: [guildID(1), guildID(2), guildID(3)])),
        .folder(GuildFolder(id: 20, guildIDs: [guildID(4)])),
    ])
    #expect(ServerOrderEditing.moving(.guild(guildID(3)), to: .after(.folder(10)), in: layout) == [
        .folder(GuildFolder(id: 10, name: "Friends", guildIDs: [guildID(3), guildID(2)])),
        .guild(guildID(1)),
        .folder(GuildFolder(id: 20, guildIDs: [guildID(4)])),
    ])
    #expect(ServerOrderEditing.moving(.guild(guildID(4)), to: .after(.folder(10)), in: layout) == [
        .folder(GuildFolder(id: 10, name: "Friends", guildIDs: [guildID(4), guildID(2), guildID(3)])),
        .guild(guildID(1)),
    ])
    // Folders never nest, so a folder dropped there lands after the whole folder.
    #expect(ServerOrderEditing.moving(.folder(20), to: .after(.folder(10)), in: layout) == [
        layout[0], layout[2], layout[1],
    ])
}

@MainActor
@Test func `rearranging servers saves Discord's layout once when the picker closes`() async throws {
    let provider = MockChatProvider(includesLongServerList: true)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let accountID = try #require(model.snapshot?.currentUser.id.description)
    let guilds = try #require(model.snapshot?.guilds)
    let original = model.serverRailItems
    try #require(original.count >= 3)

    #expect(!model.moveServerItem(original[0].id, to: .end, accountID: "another-account"))
    #expect(model.moveServerItem(original[0].id, to: .end, accountID: accountID))
    #expect(model.moveServerItem(original[2].id, to: .before(original[1].id), accountID: accountID))
    let arranged = [original[2], original[1]] + original.dropFirst(3) + [original[0]]
    #expect(model.serverRailItems == arranged)
    #expect(model.serverRailPresentation.items.map(\.id) == arranged.map(\.id))

    // A Gateway refresh before the save does not undo the arrangement.
    model.consumeGuildLayoutChanged(guilds: guilds, railItems: original)
    #expect(model.serverRailItems == arranged)
    #expect(await provider.guildLayoutRequests.isEmpty)

    model.saveServerLayout()
    #expect(await eventually { await provider.guildLayoutRequests == [arranged] })
    #expect(await eventually { !model.isSavingServerLayout && model.snapshot?.guildRailItems == arranged })
    #expect(model.serverRailItems == arranged)

    model.saveServerLayout()
    #expect(await provider.guildLayoutRequests.count == 1)
}

@MainActor
@Test func `moves during a server order save become one follow-up save`() async throws {
    let provider = MockChatProvider(includesLongServerList: true)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let accountID = try #require(model.snapshot?.currentUser.id.description)
    let original = model.serverRailItems
    try #require(original.count >= 3)

    #expect(model.moveServerItem(original[0].id, to: .end, accountID: accountID))
    model.saveServerLayout()
    #expect(model.isSavingServerLayout)
    #expect(model.moveServerItem(original[1].id, to: .end, accountID: accountID))
    #expect(model.moveServerItem(original[2].id, to: .end, accountID: accountID))
    // A close during the request waits for it instead of sending in parallel.
    model.saveServerLayout()
    let final = Array(original.dropFirst(3)) + [original[0], original[1], original[2]]

    #expect(await eventually { await provider.guildLayoutRequests.count == 2 })
    #expect(await provider.guildLayoutRequests == [
        Array(original.dropFirst()) + [original[0]],
        final,
    ])
    #expect(await eventually { !model.isSavingServerLayout })
    #expect(model.serverRailItems == final)
}

@MainActor
@Test func `a rejected server order save restores Discord's layout`() async throws {
    let provider = MockChatProvider(guildLayoutMutationFailureStatus: 400)
    let model = AppModel(launchMode: .offlineTesting, provider: provider)
    await model.start()
    let accountID = try #require(model.snapshot?.currentUser.id.description)
    let original = model.serverRailItems
    try #require(original.count >= 2)

    #expect(model.moveServerItem(original[0].id, to: .end, accountID: accountID))
    #expect(model.serverRailItems != original)
    model.saveServerLayout()

    #expect(await eventually { model.serverRailItems == original })
    #expect(model.errorMessage == "Discord did not accept the server order.")
    #expect(await provider.guildLayoutRequests.count == 1)
    #expect(!model.isSavingServerLayout)
}

@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
    for _ in 0 ..< 500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return await condition()
}
