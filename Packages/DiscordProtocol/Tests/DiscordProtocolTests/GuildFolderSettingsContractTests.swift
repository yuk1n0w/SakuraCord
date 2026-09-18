import Foundation
import SakuraCordModels
import Testing
@testable import DiscordProtocol

@Suite(.serialized)
struct GuildFolderSettingsContractTests {
    @Test func `folder settings hold only guild folders and round-trip every folder field`() throws {
        let layout = DiscordGuildLayout(
            folders: [
                .init(guildIDs: [GuildID(rawValue: 3)]),
                .init(
                    guildIDs: [GuildID(rawValue: 2), GuildID(rawValue: 1)],
                    id: -4_611_686_018_427_387_904,
                    name: "Friends",
                    colorHex: 0x58_65_F2
                ),
                // Discord writes a black folder as an empty color wrapper.
                .init(guildIDs: [GuildID(rawValue: 5)], id: 9, colorHex: 0),
            ],
            guildPositions: [GuildID(rawValue: 1), GuildID(rawValue: 2)]
        )
        let settings = DiscordSettingsProto.guildFolderSettings(layout)

        var reader = ProtoReader(data: settings)
        var topLevelFields: [Int] = []
        while let tag = reader.readTag() {
            topLevelFields.append(tag.field)
            let skipped = reader.skip(wireType: tag.wireType)
            #expect(skipped)
        }
        #expect(topLevelFields == [14])
        #expect(DiscordSettingsProto.guildLayout(from: settings) == layout)
    }

    @Test func `server order saves one settings proto patch that keeps hidden servers`() async throws {
        GuildFolderURLProtocol.reset()
        let provider = makeProvider()
        let current = DiscordGuildLayout(
            folders: [
                .init(
                    guildIDs: [GuildID(rawValue: 1), GuildID(rawValue: 2), GuildID(rawValue: 99)],
                    id: 7,
                    name: "Friends",
                    colorHex: 0x58_65_F2
                ),
                .init(guildIDs: [GuildID(rawValue: 3)]),
                .init(guildIDs: [GuildID(rawValue: 98)]),
            ],
            guildPositions: [GuildID(rawValue: 3)]
        )
        await provider.applyGuildSettingsProto(
            DiscordSettingsProto.guildFolderSettings(current).base64EncodedString()
        )

        // Servers 98 and 99 are in Discord's settings but not on the rail.
        _ = try await provider.updateGuildLayout([
            .guild(GuildID(rawValue: 3)),
            .folder(GuildFolder(
                id: 7,
                name: "Friends",
                colorHex: 0x58_65_F2,
                guildIDs: [GuildID(rawValue: 2), GuildID(rawValue: 1)]
            )),
        ])

        #expect(GuildFolderURLProtocol.requests.count == 1)
        let request = try #require(GuildFolderURLProtocol.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/api/v9/users/@me/settings-proto/1")
        #expect(request.body?.keys.sorted() == ["settings"])
        let encoded = try #require(request.body?["settings"] as? String)
        let sent = try #require(Data(base64Encoded: encoded))
        let expected = DiscordGuildLayout(
            folders: [
                .init(guildIDs: [GuildID(rawValue: 3)]),
                .init(
                    guildIDs: [GuildID(rawValue: 2), GuildID(rawValue: 1), GuildID(rawValue: 99)],
                    id: 7,
                    name: "Friends",
                    colorHex: 0x58_65_F2
                ),
                .init(guildIDs: [GuildID(rawValue: 98)]),
            ],
            guildPositions: [GuildID(rawValue: 3)]
        )
        #expect(DiscordSettingsProto.guildLayout(from: sent) == expected)
        #expect(await provider.cachedGuildLayout == expected)
    }

    private func makeProvider() -> DiscordRESTProvider {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GuildFolderURLProtocol.self]
        return DiscordRESTProvider(
            credentials: GuildFolderCredentialStore(),
            handle: CredentialHandle(accountID: "guild-folder-contract"),
            session: URLSession(configuration: configuration)
        )
    }
}

private actor GuildFolderCredentialStore: CredentialStore {
    func store(_ credential: Data, accountID: String) async throws -> CredentialHandle {
        CredentialHandle(accountID: accountID)
    }

    func credential(for handle: CredentialHandle) async throws -> Data {
        Data("guild-folder-contract-session".utf8)
    }

    func remove(_ handle: CredentialHandle) async throws {}
    func handles() async throws -> [CredentialHandle] { [] }
}

private struct CapturedGuildFolderRequest: @unchecked Sendable {
    let method: String
    let path: String
    let body: [String: Any]?
}

private final class GuildFolderURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [CapturedGuildFolderRequest] = []

    static func reset() { requests = [] }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.requestBody(request).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        Self.requests.append(
            CapturedGuildFolderRequest(
                method: request.httpMethod ?? "",
                path: request.url?.path ?? "",
                body: body
            )
        )
        // Discord answers a settings save with the account's complete
        // settings; echoing the saved folders stands in for them here.
        let settings = body?["settings"] as? String ?? ""
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"settings":"\#(settings)"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
