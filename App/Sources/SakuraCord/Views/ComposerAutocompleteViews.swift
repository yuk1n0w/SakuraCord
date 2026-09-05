import SwiftUI

struct EmojiAutocompleteList: View {
    let suggestions: [ColonAutocompleteSuggestion]
    let selectedIndex: Int
    let highlight: (Int) -> Void
    let select: (ColonAutocompleteSuggestion) -> Void

    var body: some View {
        ComposerAutocompletePanel(heading: "EMOJIS", count: suggestions.count) {
            LazyVStack(spacing: 2) {
                ForEach(suggestions.enumerated(), id: \.element.id) { index, suggestion in
                    EmojiAutocompleteRow(
                        suggestion: suggestion,
                        isSelected: index == selectedIndex,
                        select: { select(suggestion) },
                        highlight: { highlight(index) }
                    )
                }
            }
        }
    }
}

struct ComposerAutocompletePanel<Content: View>: View {
    let heading: String
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 5)
            ScrollView {
                content()
                    .padding(.horizontal, 5)
                    .padding(.bottom, 5)
            }
            .frame(height: min(340, CGFloat(max(1, count)) * 42))
        }
        .frame(maxWidth: .infinity)
        .glassEffect(
            .regular.interactive(),
            in: ConcentricRectangle(
                corners: .concentric(
                    minimum: .fixed(
                        ChatChromeMetrics.composerMinimumCornerRadius
                    )
                ),
                isUniform: true
            )
        )
        .containerShape(
            .rect(
                cornerRadius: ChatChromeMetrics.composerMinimumCornerRadius,
                style: .continuous
            )
        )
    }
}
