import Foundation
import Testing
import SakuraCordModels
@testable import SakuraCord

@Test func `Japanese detection covers kana and kanji without matching English`() {
    #expect(MessageTranslationEligibility.containsJapanese("五等分の花嫁"))
    #expect(MessageTranslationEligibility.containsJapanese("ニノが好き"))
    #expect(!MessageTranslationEligibility.containsJapanese("Nino Nakano"))
}

@Test func `automatic outgoing translation only converts an English draft`() {
    #expect(MessageTranslationEligibility.needsOutgoingTranslation("Good morning"))
    #expect(!MessageTranslationEligibility.needsOutgoingTranslation("おはよう"))
    #expect(!MessageTranslationEligibility.needsOutgoingTranslation("   "))
}

@MainActor
@Test func `automatic translation toggles independently for each conversation`() {
    let controller = MessageTranslationController()
    let first = ChannelID(rawValue: 101)
    let second = ChannelID(rawValue: 202)

    #expect(!controller.isAutomaticTranslationEnabled(for: first))
    #expect(controller.toggleAutomaticTranslation(for: first))
    #expect(controller.isAutomaticTranslationEnabled(for: first))
    #expect(!controller.isAutomaticTranslationEnabled(for: second))
    #expect(!controller.toggleAutomaticTranslation(for: first))
    #expect(!controller.isAutomaticTranslationEnabled(for: first))
}

@Test func `outgoing translation glossary preserves anime character names`() {
    let protected = MessageTranslationGlossary.protect(
        "Nino Nakano is my favourite quintuplet.",
        direction: .outgoing,
        entries: [
            MessageTranslationGlossaryEntry(
                english: "Nino Nakano",
                japanese: "中野二乃"
            ),
        ]
    )

    #expect(!protected.text.contains("Nino Nakano"))
    #expect(
        MessageTranslationGlossary.restore(
            "SakuraCordTerm0Xは私の一番好きな五つ子です。",
            replacements: protected.replacements
        ) == "中野二乃は私の一番好きな五つ子です。"
    )
}

@MainActor
@Test func `automatic outgoing translation returns Japanese without opening a sheet`() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TranslationURLProtocol.self]
    let controller = MessageTranslationController(
        client: GoogleMessageTranslationClient(
            session: URLSession(configuration: configuration)
        )
    )

    let translated = try await controller.translateOutgoingAutomatically("Good morning")

    #expect(translated == "おはよう")
    #expect(controller.presentation == nil)
}

@Test func `incoming translation glossary preserves romanized character names`() {
    let protected = MessageTranslationGlossary.protect(
        "中野二乃が一番好きです。",
        direction: .incoming,
        entries: [
            MessageTranslationGlossaryEntry(
                english: "Nino Nakano",
                japanese: "中野二乃"
            ),
        ]
    )

    #expect(!protected.text.contains("中野二乃"))
    #expect(
        MessageTranslationGlossary.restore(
            "I like sakuracordterm0x the best.",
            replacements: protected.replacements
        ) == "I like Nino Nakano the best."
    )
}

@Test func `translation glossary protects longer titles before shorter names`() {
    let protected = MessageTranslationGlossary.protect(
        "The Quintessential Quintuplets has quintuplets.",
        direction: .outgoing,
        entries: [
            MessageTranslationGlossaryEntry(
                english: "quintuplets",
                japanese: "五つ子"
            ),
            MessageTranslationGlossaryEntry(
                english: "The Quintessential Quintuplets",
                japanese: "五等分の花嫁"
            ),
        ]
    )

    #expect(protected.replacements.count == 2)
    #expect(
        MessageTranslationGlossary.restore(
            protected.text,
            replacements: protected.replacements
        ) == "五等分の花嫁 has 五つ子."
    )
}

private final class TranslationURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"[[["おはよう","Good morning",null,null]],null,"en"]"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
