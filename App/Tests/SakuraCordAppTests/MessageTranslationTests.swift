import Testing
@testable import SakuraCord

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
