import Foundation
import SakuraCordModels

extension DiscordRESTProvider {
    func applyGuildSettingsProto(
        _ encoded: String?,
        replacesAllSettings: Bool = false
    ) {
        guard
            let encoded,
            let data = Data(base64Encoded: encoded)
        else { return }
        let decodedLayout = DiscordSettingsProto.guildLayout(from: data)
        guard decodedLayout != nil || replacesAllSettings else { return }
        let layout = decodedLayout ?? DiscordGuildLayout(folders: [], guildPositions: [])
        cachedGuildLayout = layout
        // A current desktop READY can provide every guild ID and its channels
        // while omitting the catalogue metadata required to construct Guilds.
        // Preserve the settings until bootstrap's bounded guild-list fallback
        // has installed that catalogue instead of replacing the cached rail
        // with an empty layout event here.
        guard !cachedGuilds.isEmpty else { return }
        let result = Self.applyingGuildLayout(layout, to: guildsInCurrentRailOrder())
        cachedGuilds = Dictionary(uniqueKeysWithValues: result.guilds.map { ($0.id, $0) })
        guard result.railItems != cachedGuildRailItems else { return }
        cachedGuildRailItems = result.railItems
        continuation?.yield(.guildLayoutChanged(guilds: result.guilds, railItems: result.railItems))
    }

    public func updateGuildLayout(_ railItems: [GuildRailItem]) async throws -> [GuildRailItem] {
        let layout = Self.guildLayout(saving: railItems, over: cachedGuildLayout)
        let settings = DiscordSettingsProto.guildFolderSettings(layout)
        let response: UserSettingsProtoDTO = try await request(
            "/users/@me/settings-proto/1",
            method: "PATCH",
            body: ["settings": .string(settings.base64EncodedString())]
        )
        // Discord answers with the account's complete settings, which the
        // first-party client adopts in place of its own copy.
        applyGuildSettingsProto(response.settings, replacesAllSettings: true)
        return cachedGuildRailItems
    }

    /// Discord's folder layout for a rearranged rail. A server that Discord's
    /// settings list but the rail cannot show, such as one that is currently
    /// unavailable, keeps its folder instead of being dropped from the account.
    static func guildLayout(
        saving railItems: [GuildRailItem],
        over current: DiscordGuildLayout?
    ) -> DiscordGuildLayout {
        var folders = railItems.map { item -> DiscordGuildLayout.Folder in
            switch item {
            case .guild(let id):
                DiscordGuildLayout.Folder(guildIDs: [id])
            case .folder(let folder):
                DiscordGuildLayout.Folder(
                    guildIDs: folder.guildIDs,
                    id: folder.id,
                    name: folder.name,
                    colorHex: folder.colorHex
                )
            }
        }
        guard let current else {
            return DiscordGuildLayout(folders: folders, guildPositions: [])
        }
        let shown = Set(folders.flatMap(\.guildIDs))
        for folder in current.folders {
            let hidden = folder.guildIDs.filter { !shown.contains($0) }
            guard !hidden.isEmpty else { continue }
            if let id = folder.id, let index = folders.firstIndex(where: { $0.id == id }) {
                folders[index].guildIDs += hidden
            } else {
                var kept = folder
                kept.guildIDs = hidden
                folders.append(kept)
            }
        }
        return DiscordGuildLayout(folders: folders, guildPositions: current.guildPositions)
    }

    func guildsInCurrentRailOrder() -> [Guild] {
        let existingOrder = cachedGuildRailItems.flatMap { item -> [GuildID] in
            switch item {
            case .guild(let id): [id]
            case .folder(let folder): folder.guildIDs
            }
        }
        let existingSet = Set(existingOrder)
        let orderedGuilds =
            existingOrder.compactMap { cachedGuilds[$0] }
                + cachedGuilds.values
                .filter { !existingSet.contains($0.id) }
                .sorted { $0.id.rawValue > $1.id.rawValue }
        return orderedGuilds
    }
}

extension DiscordSettingsProto {
    /// A partial settings proto holding only top-level field 14, which is how
    /// Discord's own client saves a rearranged server list.
    static func guildFolderSettings(_ layout: DiscordGuildLayout) -> Data {
        var guildFolders = Data()
        for folder in layout.folders {
            var payload = protoPackedFixed64Field(1, folder.guildIDs.map(\.rawValue))
            if let id = folder.id {
                payload.append(protoWrappedVarintField(2, UInt64(bitPattern: id)))
            }
            if let name = folder.name, !name.isEmpty {
                payload.append(protoLengthDelimitedField(3, protoStringField(1, name)))
            }
            if let colorHex = folder.colorHex {
                payload.append(protoWrappedVarintField(4, UInt64(colorHex)))
            }
            guildFolders.append(protoLengthDelimitedField(1, payload))
        }
        guildFolders.append(protoPackedFixed64Field(2, layout.guildPositions.map(\.rawValue)))
        return protoLengthDelimitedField(14, guildFolders)
    }

    /// Proto3 omits a zero wrapped value, leaving an empty wrapper.
    private static func protoWrappedVarintField(_ field: Int, _ value: UInt64) -> Data {
        protoLengthDelimitedField(field, value == 0 ? Data() : protoVarintField(1, value))
    }

    private static func protoPackedFixed64Field(_ field: Int, _ values: [UInt64]) -> Data {
        guard !values.isEmpty else { return Data() }
        var packed = Data(capacity: values.count * 8)
        for value in values {
            withUnsafeBytes(of: value.littleEndian) { packed.append(contentsOf: $0) }
        }
        return protoLengthDelimitedField(field, packed)
    }
}
